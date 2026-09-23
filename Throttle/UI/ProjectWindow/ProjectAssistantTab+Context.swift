import AppKit
import GRDB
import SwiftUI

extension ProjectAssistantTab {
    /// Build the project context once per session. Loads:
    /// - CLAUDE.md and .claude/settings.json from the project root
    /// - Globally-installed hook scripts from ~/.claude/hooks/
    /// - MCP server names from ~/.claude/settings.json (MCP config lives here)
    /// - Per-project tokens, cost, model split for the last 7 days
    func ensureContext() async -> ProjectChatContext {
        if let runtimeOverride { return await runtimeOverride.context(project) }
        let generation = contextGeneration
        if let loadedContext { return loadedContext }
        let claudeMd = project.claudeMdURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let settingsJSON = project.settingsJSONURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let stats = await contextStats(database: appState.database, encoded: project.encodedName)

        // Read global hooks the user has installed and the MCP server
        // list out of ~/.claude/. These are shared across all projects
        // so we always include them in every project's context.
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        let hooksDir = claudeDir.appendingPathComponent("hooks", isDirectory: true)
        var hookScripts: [String: String] = [:]
        var hookScriptPaths: [String: String] = [:]
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: hooksDir.path) {
            for name in entries where name.hasSuffix(".sh") {
                let url = hooksDir.appendingPathComponent(name)
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    let key = "~/.claude/hooks/\(name)"
                    hookScripts[key] = content
                    hookScriptPaths[key] = url.path
                }
            }
        }
        var mcpServers: [String] = []
        let globalSettingsURL = claudeDir.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: globalSettingsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let mcps = obj["mcpServers"] as? [String: Any] {
            mcpServers = mcps.keys.sorted()
        }

        var ctx = ProjectChatContext(
            projectName: project.displayName,
            projectPath: project.projectPath,
            claudeMd: claudeMd,
            settingsJSON: settingsJSON,
            weeklyTokens: stats.weekly,
            modelSplit: stats.split,
            hookScripts: hookScripts,
            mcpServers: mcpServers,
            costEUR: stats.cost
        )
        ctx.claudeMdPath = project.claudeMdURL?.path
        ctx.settingsJSONPath = project.settingsJSONURL?.path
        ctx.hookScriptPaths = hookScriptPaths
        if contextGeneration == generation, !Task.isCancelled { loadedContext = ctx }
        return ctx
    }

    private struct StatsBundle: Sendable {
        var weekly: Int = 0
        var split: [(String, Double)] = []
        var cost: Double = 0
    }

    private func contextStats(database: any DatabaseWriter, encoded: String) async -> StatsBundle {
        return await Task.detached {
            var stats = StatsBundle()
            _ = try? database.read { connection in
                stats.weekly = (try? StatsDataService.tokensForProject(
                    in: connection, encodedName: encoded, fromHoursAgo: 0, toHoursAgo: 168)) ?? 0
                stats.split = (try? StatsDataService.modelSplitForProject(
                    in: connection, encodedName: encoded, fromHoursAgo: 0, toHoursAgo: 168)) ?? []
                stats.cost = (try? StatsDataService.costForProject(
                    in: connection, encodedName: encoded, fromHoursAgo: 0, toHoursAgo: 168)) ?? 0
            }
            return stats
        }.value
    }

    /// Run the deterministic 7-rule audit (LocalAuditEngine) and post the
    /// findings as a synthetic assistant message. No AI tokens consumed.
    /// The output uses the same Markdown shape the AI uses, so the user
    /// can't tell from the chat UI which engine produced the answer —
    /// the only difference is the toolbar button they pressed.
    func runLocalAudit() async {
        // Show a "user" bubble so the chat looks like a real turn —
        // makes the result feel like an answer to a question.
        let userMsg = ChatMessage(role: .user, content: String(localized: "Run local audit (deterministic, no AI)."))
        transcript.append(userMsg)

        let claudeMdText = project.claudeMdURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let claudeMdBytes: Int = project.claudeMdURL
            .flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
        let settingsJSONText = project.settingsJSONURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }

        let hooksDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/hooks", isDirectory: true)
        let hooksPresent: [String]
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: hooksDir.path) {
            hooksPresent = entries.filter { $0.hasSuffix(".sh") }
        } else {
            hooksPresent = []
        }

        let claudeMdPair: (text: String, bytes: Int)? = {
            guard let text = claudeMdText else { return nil }
            return (text: text, bytes: claudeMdBytes > 0 ? claudeMdBytes : text.utf8.count)
        }()

        let findings = LocalAuditEngine.audit(
            claudeMd: claudeMdPair,
            settingsJSON: settingsJSONText,
            hooksPresent: hooksPresent
        )
        let markdown = LocalAuditEngine.renderMarkdown(findings: findings)
        transcript.append(ChatMessage(role: .assistant, content: markdown))
    }
}
