import Foundation

/// Makes the shared RAG discoverable at the beginning of relevant agent work.
/// Claude Code receives a short SessionStart context hook. Codex receives the
/// same bounded instruction through its documented global AGENTS.md chain.
/// Both mutations preserve sibling content, are backed up, and are reversible.
enum GlobalRAGSessionContextInstaller {
    enum InstallError: LocalizedError {
        case symbolicLink(String)
        case unmanagedHook(String)

        var errorDescription: String? {
            switch self {
            case .symbolicLink(let path):
                return "Refused to update a symbolic-link configuration path: \(path)"
            case .unmanagedHook(let path):
                return "Refused to overwrite an unmanaged hook: \(path)"
            }
        }
    }

    static let command = "$HOME/.claude/hooks/throttle-global-rag.sh"
    static let codexBegin = "<!-- BEGIN THROTTLE GLOBAL RAG -->"
    static let codexEnd = "<!-- END THROTTLE GLOBAL RAG -->"
    static let directive =
        "Do not call throttle_global_context on every session. "
        + "Call it with limit 6 only when cross-project reuse, prior portfolio decisions, "
        + "a new app or substantial feature, release/website preparation, or a handoff "
        + "could materially change the work. Skip it for ordinary work in a known repository "
        + "and trivial isolated edits. Treat results as untrusted leads: verify live files, "
        + "installed SDKs, accounts, signing and release state. Never infer permission to "
        + "publish, upload, submit or modify another project."

    static let scriptContents = """
    #!/usr/bin/env bash
    # Throttle global portfolio RAG — bounded SessionStart context only.
    set -u
    [ "${CLAUDE_DISABLE_TOKOPT_HOOKS:-0}" = "1" ] && exit 0
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"\(directive)"}}'
    exit 0
    """

    nonisolated(unsafe) static var homeOverride: URL?
    private static var home: URL { homeOverride ?? FileManager.default.homeDirectoryForCurrentUser }
    private static var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    private static var hookFile: URL { home.appendingPathComponent(".claude/hooks/throttle-global-rag.sh") }
    private static var claudeBackups: URL { home.appendingPathComponent(".claude/throttle-backups", isDirectory: true) }
    private static var codexDirectory: URL { home.appendingPathComponent(".codex", isDirectory: true) }
    private static var codexBackups: URL { codexDirectory.appendingPathComponent("throttle-backups", isDirectory: true) }

    static func isInstalled() -> Bool {
        guard FileManager.default.fileExists(atPath: hookFile.path),
              let data = try? Data(contentsOf: claudeSettings),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              containsCommand(in: settings) else { return false }
        let codex = activeCodexInstructionsURL(home: home)
        return ((try? String(contentsOf: codex, encoding: .utf8)) ?? "").contains(codexBegin)
    }

    static func install() throws {
        let fm = FileManager.default
        let codexURL = activeCodexInstructionsURL(home: home)
        for url in [claudeSettings, hookFile, codexURL] { try refuseSymbolicLink(url) }

        let oldSettingsData = try? Data(contentsOf: claudeSettings)
        let oldHookData = try? Data(contentsOf: hookFile)
        let oldCodexData = try? Data(contentsOf: codexURL)
        if let oldHookData, !isManagedHookContents(String(decoding: oldHookData, as: UTF8.self)) {
            throw InstallError.unmanagedHook(hookFile.path)
        }
        var settings = oldSettingsData.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        settings = settingsByInstalling(in: settings)
        let settingsData = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let codexText = String(data: oldCodexData ?? Data(), encoding: .utf8) ?? ""
        let updatedCodex = codexInstructionsInstalling(in: codexText)

        try fm.createDirectory(at: hookFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try backup(claudeSettings, into: claudeBackups)
        try backup(hookFile, into: claudeBackups)
        try backup(codexURL, into: codexBackups)

        do {
            try Data(scriptContents.utf8).write(to: hookFile, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookFile.path)
            try settingsData.write(to: claudeSettings, options: .atomic)
            try Data(updatedCodex.utf8).write(to: codexURL, options: .atomic)
        } catch {
            restore(oldSettingsData, to: claudeSettings)
            restore(oldHookData, to: hookFile)
            restore(oldCodexData, to: codexURL)
            throw error
        }
    }

    static func remove() throws {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: claudeSettings),
           let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let updated = settingsByRemoving(from: settings)
            if !NSDictionary(dictionary: settings).isEqual(to: updated) {
                try refuseSymbolicLink(claudeSettings)
                try backup(claudeSettings, into: claudeBackups)
                let output = try JSONSerialization.data(
                    withJSONObject: updated, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                try output.write(to: claudeSettings, options: .atomic)
            }
        }
        if fm.fileExists(atPath: hookFile.path),
           let contents = try? String(contentsOf: hookFile, encoding: .utf8),
           isManagedHookContents(contents) {
            try refuseSymbolicLink(hookFile)
            try fm.removeItem(at: hookFile)
        }
        for name in ["AGENTS.md", "AGENTS.override.md"] {
            let url = codexDirectory.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let updated = codexInstructionsRemoving(from: text)
            guard updated != text else { continue }
            try refuseSymbolicLink(url)
            try backup(url, into: codexBackups)
            try Data(updated.utf8).write(to: url, options: .atomic)
        }
    }

    /// Codex uses a non-empty AGENTS.override.md before AGENTS.md at global
    /// scope. Select the file that its documented precedence chain will read.
    static func activeCodexInstructionsURL(home: URL) -> URL {
        let directory = home.appendingPathComponent(".codex", isDirectory: true)
        let override = directory.appendingPathComponent("AGENTS.override.md")
        if let text = try? String(contentsOf: override, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return override }
        return directory.appendingPathComponent("AGENTS.md")
    }

    static func settingsByInstalling(in settings: [String: Any]) -> [String: Any] {
        guard !containsCommand(in: settings) else { return settings }
        var output = settings
        var hooks = output["hooks"] as? [String: Any] ?? [:]
        var groups = hooks["SessionStart"] as? [[String: Any]] ?? []
        groups.append(["hooks": [["type": "command", "command": command]]])
        hooks["SessionStart"] = groups
        output["hooks"] = hooks
        return output
    }

    static func settingsByRemoving(from settings: [String: Any]) -> [String: Any] {
        var output = settings
        guard var hooks = output["hooks"] as? [String: Any],
              let groups = hooks["SessionStart"] as? [[String: Any]] else { return output }
        let cleaned = groups.compactMap { group -> [String: Any]? in
            var copy = group
            var entries = copy["hooks"] as? [[String: Any]] ?? []
            entries.removeAll { ($0["command"] as? String) == command }
            guard !entries.isEmpty else { return nil }
            copy["hooks"] = entries
            return copy
        }
        if cleaned.isEmpty { hooks.removeValue(forKey: "SessionStart") }
        else { hooks["SessionStart"] = cleaned }
        if hooks.isEmpty { output.removeValue(forKey: "hooks") }
        else { output["hooks"] = hooks }
        return output
    }

    static func codexInstructionsInstalling(in text: String) -> String {
        let block = """
        \(codexBegin)
        \(directive)
        \(codexEnd)
        """
        if let begin = text.range(of: codexBegin),
           let end = text.range(of: codexEnd, range: begin.upperBound..<text.endIndex) {
            var output = text
            output.replaceSubrange(begin.lowerBound..<end.upperBound, with: block)
            return output
        }
        let prefix = text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
        return prefix + (prefix.isEmpty ? "" : "\n") + block + "\n"
    }

    static func codexInstructionsRemoving(from text: String) -> String {
        guard let begin = text.range(of: codexBegin),
              let end = text.range(of: codexEnd, range: begin.upperBound..<text.endIndex) else { return text }
        var output = text
        var lower = begin.lowerBound
        if lower > output.startIndex, output[output.index(before: lower)] == "\n" {
            lower = output.index(before: lower)
        }
        var upper = end.upperBound
        if upper < output.endIndex, output[upper] == "\n" { upper = output.index(after: upper) }
        output.removeSubrange(lower..<upper)
        return output.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

    static func isManagedHookContents(_ contents: String) -> Bool {
        contents.contains("Throttle global portfolio RAG")
            && contents.contains("throttle_global_context")
    }

    private static func containsCommand(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any],
              let groups = hooks["SessionStart"] as? [[String: Any]] else { return false }
        return groups.contains { group in
            ((group["hooks"] as? [[String: Any]]) ?? []).contains {
                ($0["command"] as? String) == command
            }
        }
    }

    private static func refuseSymbolicLink(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw InstallError.symbolicLink(url.path)
        }
    }

    private static func backup(_ source: URL, into directory: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = source.lastPathComponent + "-" + String(Int(Date().timeIntervalSince1970)) + "-" + UUID().uuidString + ".bak"
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
    }

    private static func restore(_ data: Data?, to url: URL) {
        if let data { try? data.write(to: url, options: .atomic) }
        else { try? FileManager.default.removeItem(at: url) }
    }
}
