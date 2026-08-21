import Darwin
import Foundation

/// A coding-agent runtime that can own one native Cockpit session.
///
/// A Throttle mission may span several native sessions, but a tab always has one
/// concrete owner. This keeps process control and resume semantics honest: Claude
/// and Codex do not share an internal conversation identifier.
enum AgentRuntime: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case codex
    case local
    case terminal

    var id: String { rawValue }
    var label: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .local: return "Local"
        case .terminal: return "Terminal"
        }
    }
    var shortLabel: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .local: return "Local"
        case .terminal: return "Terminal"
        }
    }
    var executable: String? {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .local, .terminal: return nil
        }
    }
    var symbol: String {
        switch self {
        case .claudeCode: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .local: return "cpu"
        case .terminal: return "terminal"
        }
    }
    /// Only these runtimes emit native CLI transcripts/cost metadata that Throttle
    /// can track and restore reliably.
    var usesTranscript: Bool { self == .claudeCode || self == .codex }
}

/// User intent for the next mission/session. Changing this never kills or
/// rewrites a running agent; switching a live mission goes through a handoff.
enum MissionRoutingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case claudeCode
    case codex
    case hybrid

    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return String(localized: "Auto")
        case .claudeCode: return String(localized: "Claude Code")
        case .codex: return String(localized: "Codex")
        case .hybrid: return String(localized: "Hybrid")
        }
    }

    var detail: String {
        switch self {
        case .automatic: return String(localized: "Claude first; offer Codex after a confirmed limit")
        case .claudeCode: return String(localized: "Start new missions with Claude Code")
        case .codex: return String(localized: "Start new missions with Codex")
        case .hybrid: return String(localized: "Balance missions; one writer per checkout; structured handoffs")
        }
    }
}

struct MissionGitEvidence: Equatable, Sendable {
    let branch: String?
    let head: String?
    let statusLines: [String]

    static let unavailable = MissionGitEvidence(branch: nil, head: nil, statusLines: [])
}

struct MissionHandoffContext: Equatable, Sendable {
    var completed: String
    var remaining: String
    var validation: String
    var blockers: String
    var recentConversation: String = ""

    static let empty = MissionHandoffContext(
        completed: "", remaining: "", validation: "", blockers: "", recentConversation: ""
    )
}

struct MissionCapabilityInventory: Equatable, Sendable {
    let skills: [String]
    let mcpServers: [String]

    static let empty = MissionCapabilityInventory(skills: [], mcpServers: [])
}

/// Names-only capability map used during a provider handoff. It never contains
/// commands, arguments, URLs, environment values, tokens, or skill contents.
struct MissionCapabilityCompatibility: Equatable, Sendable {
    let source: MissionCapabilityInventory
    let target: MissionCapabilityInventory

    static let empty = MissionCapabilityCompatibility(source: .empty, target: .empty)

    var sharedSkills: [String] { intersection(source.skills, target.skills) }
    var missingSkillsOnTarget: [String] { difference(source.skills, target.skills) }
    var sharedMCPServers: [String] { intersection(source.mcpServers, target.mcpServers) }
    var missingMCPServersOnTarget: [String] { difference(source.mcpServers, target.mcpServers) }

    private func intersection(_ lhs: [String], _ rhs: [String]) -> [String] {
        let right = Set(rhs.map { $0.lowercased() })
        return lhs.filter { right.contains($0.lowercased()) }.sorted()
    }

    private func difference(_ lhs: [String], _ rhs: [String]) -> [String] {
        let right = Set(rhs.map { $0.lowercased() })
        return lhs.filter { !right.contains($0.lowercased()) }.sorted()
    }
}

struct MissionHandoff: Identifiable, Equatable, Sendable {
    let id = UUID()
    let sourceTabID: UUID
    let missionID: UUID
    let projectName: String
    let cwd: String
    let source: AgentRuntime
    let target: AgentRuntime
    let sourceSessionID: String?
    var objective: String
    var context: MissionHandoffContext = .empty
    var capabilities: MissionCapabilityCompatibility = .empty
    let git: MissionGitEvidence

    var prompt: String { MissionRuntimeService.render(self) }
}

enum MissionRuntimeService {
    private struct CodexSessionSnapshot {
        let builtAt: Date
        let rootPath: String
        let newestByCWD: [String: (id: String, mtime: Date)]
        let sessionIDsByCWD: [String: Set<String>]
    }

    private final class ProcessCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()

        func append(_ data: Data, limit: Int) {
            lock.withLock {
                let remaining = max(0, limit - value.count)
                if remaining > 0 { value.append(data.prefix(remaining)) }
            }
        }

        func load() -> Data { lock.withLock { value } }
    }

    private final class CodexSessionIndex: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: CodexSessionSnapshot?
        private var builds = 0

        func current(root: URL, maxAge: TimeInterval = 8) -> CodexSessionSnapshot? {
            lock.withLock {
                guard let snapshot,
                      snapshot.rootPath == root.standardizedFileURL.path,
                      Date().timeIntervalSince(snapshot.builtAt) <= maxAge else { return nil }
                return snapshot
            }
        }

        func store(_ value: CodexSessionSnapshot) {
            lock.withLock {
                snapshot = value
                builds += 1
            }
        }

        var buildCount: Int { lock.withLock { builds } }
    }

    private static let codexSessionIndex = CodexSessionIndex()

    /// Resolve only the runtime for a *new* session. Existing sessions are never
    /// silently switched. Hybrid deliberately starts with one writer; the user can
    /// create a bounded handoff to the other runtime from the session menu.
    static func resolve(_ mode: MissionRoutingMode, claudeRateLimited: Bool) -> AgentRuntime {
        switch mode {
        case .automatic: return claudeRateLimited ? .codex : .claudeCode
        case .claudeCode: return .claudeCode
        case .codex: return .codex
        case .hybrid: return claudeRateLimited ? .codex : .claudeCode
        }
    }

    /// Hybrid distributes independent new missions across providers while still
    /// enforcing a single writer per checkout. Auto remains availability routing.
    static func resolveHybrid(
        claudeRateLimited: Bool,
        claudeSessions: Int,
        codexSessions: Int
    ) -> AgentRuntime {
        guard !claudeRateLimited else { return .codex }
        return claudeSessions <= codexSessions ? .claudeCode : .codex
    }

    static func hybridKickoff(runtime: AgentRuntime) -> String {
        [
            "This is a Throttle hybrid mission owned by \(runtime.label).",
            "Work only on the explicit task for this session and treat the current checkout as source of truth.",
            "Start read-only, preserve changes, and keep a ledger of completed work, remaining work, validations,",
            "and blockers so the mission can be handed to the other provider without copying private transcript",
            "content. Only one coding agent may write in this checkout at a time."
        ].joined(separator: " ")
    }

    /// A compact, provider-neutral continuation packet. It intentionally contains
    /// metadata and Git evidence, not transcript text or secrets.
    static func render(_ handoff: MissionHandoff) -> String {
        let objective = handoff.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = handoff.git.branch ?? "unknown"
        let head = handoff.git.head ?? "unknown"
        let sourceSession = handoff.sourceSessionID ?? "not available"
        let status = handoff.git.statusLines.isEmpty
            ? "- Working tree status unavailable or clean. Recheck it yourself."
            : handoff.git.statusLines.prefix(40).map { "- `\($0)`" }.joined(separator: "\n")
        let completed = normalized(
            handoff.context.completed, fallback: "Not provided; infer nothing and inspect the diff."
        )
        let remaining = normalized(
            handoff.context.remaining, fallback: "Not provided; re-establish from repository evidence."
        )
        let validation = normalized(
            handoff.context.validation, fallback: "No validation evidence was supplied; rerun relevant checks."
        )
        let blockers = normalized(
            handoff.context.blockers, fallback: "No blockers were recorded; verify independently."
        )
        let recentConversation = handoff.context.recentConversation
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let portableContext = recentConversation.isEmpty
            ? "No conversation excerpt was available. Use the ledger and repository evidence."
            : recentConversation
        let sharedSkills = names(handoff.capabilities.sharedSkills)
        let missingSkills = names(handoff.capabilities.missingSkillsOnTarget)
        let sharedMCP = names(handoff.capabilities.sharedMCPServers)
        let missingMCP = names(handoff.capabilities.missingMCPServersOnTarget)

        return """
        Continue mission \(handoff.missionID.uuidString).
        Runtime handoff: \(handoff.source.label) → \(handoff.target.label).

        Project: \(handoff.projectName)
        Working directory: \(handoff.cwd)
        Previous native session: \(sourceSession)
        Objective: \(objective.isEmpty ? "Continue the current project work from fresh local evidence." : objective)

        Structured continuation ledger:
        - Completed: \(completed)
        - Remaining: \(remaining)
        - Validation: \(validation)
        - Blockers / risks: \(blockers)

        Recent provider-neutral conversation excerpt (user/assistant text only; no tool output or hidden reasoning):
        \(portableContext)

        Capability compatibility (names only; no configuration or secrets):
        - Skills available on both providers: \(sharedSkills)
        - Source skills unavailable on target: \(missingSkills)
        - MCP servers configured on both providers: \(sharedMCP)
        - Source MCP servers unavailable on target: \(missingMCP)
        - Never assume a missing capability exists. Use a repository-local equivalent or ask before changing provider configuration.

        Fresh handoff snapshot:
        - Branch: \(branch)
        - HEAD: \(head)
        - Source runtime: \(handoff.source.label)

        Working tree:
        \(status)

        Safety and continuation rules:
        - Start read-only: inspect Git status, the diff, repository instructions, and recent history.
        - Preserve every existing tracked and untracked change.
        - Never reset, clean, stash, rewrite, commit, push, or publish without explicit authorization.
        - Treat this packet as orientation, not proof. Revalidate the current checkout before acting.
        - Continue the objective with the smallest safe change and report exact validation evidence.
        """
    }

    private static func normalized(_ value: String, fallback: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return cleaned.isEmpty ? fallback : cleaned
    }

    private static func names(_ values: [String]) -> String {
        values.isEmpty ? "none detected" : values.joined(separator: ", ")
    }

    /// Compare provider capabilities without mutating either provider. Only the
    /// definition names escape this function; config bodies and SKILL.md content
    /// are never copied into the handoff packet.
    nonisolated static func capabilityCompatibility(
        source: AgentRuntime,
        target: AgentRuntime,
        cwd: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> MissionCapabilityCompatibility {
        MissionCapabilityCompatibility(
            source: capabilityInventory(runtime: source, cwd: cwd, home: home),
            target: capabilityInventory(runtime: target, cwd: cwd, home: home)
        )
    }

    nonisolated static func capabilityInventory(
        runtime: AgentRuntime,
        cwd: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> MissionCapabilityInventory {
        guard runtime.usesTranscript else {
            return MissionCapabilityInventory(skills: [], mcpServers: [])
        }
        let fm = FileManager.default
        let providerDir = runtime == .claudeCode ? ".claude" : ".codex"
        let skillRoots = [
            home.appendingPathComponent("\(providerDir)/skills", isDirectory: true),
            URL(fileURLWithPath: cwd, isDirectory: true)
                .appendingPathComponent("\(providerDir)/skills", isDirectory: true)
        ]
        var skills = Set<String>()
        for root in skillRoots {
            guard let children = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children where fm.fileExists(
                atPath: child.appendingPathComponent("SKILL.md").path
            ) {
                skills.insert(child.lastPathComponent)
            }
        }

        let mcp: Set<String>
        switch runtime {
        case .claudeCode:
            mcp = claudeMCPNames(cwd: cwd, home: home)
        case .codex:
            mcp = codexMCPNames(config: home.appendingPathComponent(".codex/config.toml"))
        case .local, .terminal:
            mcp = []
        }
        return MissionCapabilityInventory(skills: skills.sorted(), mcpServers: mcp.sorted())
    }

    nonisolated private static func claudeMCPNames(cwd: String, home: URL) -> Set<String> {
        var names = Set<String>()
        if let root = jsonObject(home.appendingPathComponent(".claude.json")) {
            names.formUnion(dictionaryKeys(root["mcpServers"]))
            if let projects = root["projects"] as? [String: Any],
               let local = projects[cwd] as? [String: Any] {
                names.formUnion(dictionaryKeys(local["mcpServers"]))
            }
        }
        let projectConfig = URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(".mcp.json")
        if let root = jsonObject(projectConfig) {
            names.formUnion(dictionaryKeys(root["mcpServers"]))
        }
        return names
    }

    nonisolated private static func codexMCPNames(config: URL) -> Set<String> {
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return [] }
        var names = Set<String>()
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[mcp_servers."), let close = line.firstIndex(of: "]") else { continue }
            var name = String(line[line.index(line.startIndex, offsetBy: 13)..<close])
                .trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 {
                name.removeFirst(); name.removeLast()
            }
            if !name.isEmpty, !name.contains(".") { names.insert(name) }
        }
        return names
    }

    nonisolated private static func jsonObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return value
    }

    nonisolated private static func dictionaryKeys(_ value: Any?) -> Set<String> {
        Set((value as? [String: Any])?.keys ?? Dictionary<String, Any>().keys)
    }

    /// Build a bounded snapshot without evaluating shell text from the repository.
    /// `git` is invoked with argument arrays and a fixed cwd; failures remain honest.
    nonisolated static func gitEvidence(at cwd: String) -> MissionGitEvidence {
        let branch = runGit(["branch", "--show-current"], cwd: cwd)?.first
        let head = runGit(["rev-parse", "--short", "HEAD"], cwd: cwd)?.first
        let status = runGit(["status", "--short", "--branch"], cwd: cwd) ?? []
        return MissionGitEvidence(branch: branch, head: head, statusLines: status)
    }

    nonisolated private static func runGit(_ arguments: [String], cwd: String) -> [String]? {
        runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            cwd: cwd
        )
    }

    /// Drain stdout while the child is running. Waiting before reading can fill
    /// the pipe buffer and deadlock on a large dirty working tree.
    nonisolated static func runProcess(
        executable: URL,
        arguments: [String],
        cwd: String,
        outputLimit: Int = 64 * 1024,
        timeout: TimeInterval = 5
    ) -> [String]? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let readGroup = DispatchGroup()
        let readQueue = DispatchQueue(label: "app.throttle.process-output", qos: .userInteractive)
        let capture = ProcessCapture()
        readGroup.enter()
        readQueue.async {
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                capture.append(data, limit: outputLimit)
            }
            readGroup.leave()
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            try? pipe.fileHandleForReading.close()
            readGroup.wait()
            return nil
        }
        guard exited.wait(timeout: .now() + max(0.05, timeout)) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 0.5)
            }
            readGroup.wait()
            return nil
        }
        readGroup.wait()
        guard process.terminationStatus == 0 else { return nil }
        guard let text = String(data: capture.load(), encoding: .utf8) else { return nil }
        return text.split(separator: "\n").map(String.init)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A handoff always starts a new native conversation. Resuming a target
    /// provider's unrelated "newest session" would discard the handoff prompt and
    /// can accidentally attach this mission to older work in the same checkout.
    static func shouldDiscoverResumeSession(initialPrompt: String?) -> Bool {
        initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    /// Validate Claude's native identity just as strictly as Codex's. The two CLIs
    /// both use UUID-looking identifiers, so shape validation alone cannot prevent
    /// a Codex UUID from being submitted to `claude --resume`.
    nonisolated static func claudeSessionExists(
        id: String,
        cwd: String,
        projectsRoot: URL? = nil
    ) -> Bool {
        claudeSessionURL(id: id, cwd: cwd, projectsRoot: projectsRoot) != nil
    }

    /// Build a bounded, local continuation excerpt from native transcripts. Only
    /// explicit user/assistant text is copied: tool calls/results, system prompts,
    /// hidden reasoning and command output are excluded. The caller displays the
    /// excerpt for review before sending it to the other provider.
    nonisolated static func portableConversationContext(
        runtime: AgentRuntime,
        sessionID: String?,
        cwd: String,
        claudeProjectsRoot: URL? = nil,
        codexSessionsRoot: URL? = nil,
        maxCharacters: Int = 12_000
    ) -> String {
        guard runtime.usesTranscript else { return "" }
        guard let sessionID, maxCharacters > 0 else { return "" }
        let url: URL?
        switch runtime {
        case .claudeCode:
            url = claudeSessionURL(id: sessionID, cwd: cwd, projectsRoot: claudeProjectsRoot)
        case .codex:
            url = codexSessionURL(id: sessionID, cwd: cwd, sessionsRoot: codexSessionsRoot)
        case .local, .terminal:
            return ""
        }
        guard let url, let lines = tailJSONLines(url: url, byteLimit: 2 * 1024 * 1024) else { return "" }

        var messages: [(role: String, text: String)] = []
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = transcriptMessage(from: object, runtime: runtime) else { continue }
            let cleaned = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            if messages.last?.role == message.role && messages.last?.text == cleaned { continue }
            messages.append((message.role, cleaned))
        }

        var selected: [String] = []
        var used = 0
        for message in messages.reversed() {
            let label = message.role == "user" ? "USER" : "ASSISTANT"
            let block = "\(label): \(message.text)"
            let remaining = maxCharacters - used
            guard remaining > label.count + 4 else { break }
            let bounded = block.count > remaining ? String(block.suffix(remaining)) : block
            selected.append(bounded)
            used += bounded.count + 2
            if used >= maxCharacters { break }
        }
        return selected.reversed().joined(separator: "\n\n")
    }

    nonisolated private static func claudeSessionURL(
        id: String,
        cwd: String,
        projectsRoot: URL?
    ) -> URL? {
        let root = projectsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        let encoded = MultiCockpitModel.claudeProjectDirName(cwd)
        let url = root.appendingPathComponent(encoded, isDirectory: true)
            .appendingPathComponent(id).appendingPathExtension("jsonl")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    nonisolated private static func codexSessionURL(
        id: String,
        cwd: String,
        sessionsRoot: URL?
    ) -> URL? {
        let root = sessionsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let lines = prefixJSONLines(url: url, byteLimit: 64 * 1024) else { continue }
            for line in lines.prefix(12) {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      object["type"] as? String == "session_meta",
                      let payload = object["payload"] as? [String: Any] else { continue }
                if payload["id"] as? String == id && payload["cwd"] as? String == cwd { return url }
                break
            }
        }
        return nil
    }

    nonisolated private static func transcriptMessage(
        from object: [String: Any], runtime: AgentRuntime
    ) -> (role: String, text: String)? {
        let message: [String: Any]
        switch runtime {
        case .claudeCode:
            guard let type = object["type"] as? String, type == "user" || type == "assistant",
                  let value = object["message"] as? [String: Any] else { return nil }
            message = value
        case .codex:
            guard object["type"] as? String == "response_item",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "message" else { return nil }
            message = payload
        case .local, .terminal:
            return nil
        }
        guard let role = message["role"] as? String, role == "user" || role == "assistant" else { return nil }
        if let text = message["content"] as? String { return (role, text) }
        guard let content = message["content"] as? [[String: Any]] else { return nil }
        let allowed = runtime == .codex
            ? Set(["input_text", "output_text"])
            : Set(["text"])
        let text = content.compactMap { item -> String? in
            guard let type = item["type"] as? String, allowed.contains(type) else { return nil }
            return item["text"] as? String
        }.joined(separator: "\n")
        return text.isEmpty ? nil : (role, text)
    }

    nonisolated private static func prefixJSONLines(url: URL, byteLimit: Int) -> [Data]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: byteLimit)) ?? Data()
        return data.split(separator: 0x0A).map(Data.init)
    }

    nonisolated private static func tailJSONLines(url: URL, byteLimit: UInt64) -> [Data]? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let end = try? handle.seekToEnd() else { return nil }
        defer { try? handle.close() }
        let start = end > byteLimit ? end - byteLimit : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return nil }
        var lines = data.split(separator: 0x0A).map(Data.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    /// Discover the newest Codex rollout for a cwd from its observed local
    /// session-store shape. The parser reads only the bounded session_meta
    /// prefix and never indexes prompts or responses.
    nonisolated static func newestCodexSession(
        cwd: String,
        since: Date,
        sessionsRoot: URL? = nil
    ) -> (id: String, mtime: Date)? {
        let root = sessionsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let snapshot = codexSessionIndex.current(root: root) ?? buildCodexSessionIndex(root: root)
        guard let match = snapshot.newestByCWD[cwd],
              match.mtime >= since.addingTimeInterval(-5) else { return nil }
        return match
    }

    /// The rollout file backing a Codex session id.
    ///
    /// Codex names rollouts `rollout-<iso timestamp>-<uuid>.jsonl` and files them
    /// under YYYY/MM/DD, so neither the path nor the name can be derived from the
    /// id alone — it has to be found. Bounded to the same three-day window the rest
    /// of the Codex reading uses.
    nonisolated static func codexRolloutURL(
        id: String,
        now: Date = Date(),
        sessionsRoot: URL? = nil
    ) -> URL? {
        let root = sessionsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        for offset in 0..<3 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let p = calendar.dateComponents([.year, .month, .day], from: day)
            guard let y = p.year, let m = p.month, let d = p.day else { continue }
            let dir = root
                .appendingPathComponent(String(format: "%04d", y), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", m), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", d), isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            if let hit = files.first(where: {
                $0.pathExtension == "jsonl" && $0.lastPathComponent.contains(id)
            }) { return hit }
        }
        return nil
    }

    nonisolated static var codexSessionIndexBuildCount: Int { codexSessionIndex.buildCount }

    /// Validate a persisted native identity before asking Codex to resume it.
    /// This prevents a Claude UUID or a session from another machine/store from
    /// producing the opaque `No saved session found` failure.
    nonisolated static func codexSessionExists(
        id: String,
        cwd: String,
        sessionsRoot: URL? = nil
    ) -> Bool {
        let root = sessionsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let snapshot = codexSessionIndex.current(root: root) ?? buildCodexSessionIndex(root: root)
        return snapshot.sessionIDsByCWD[cwd]?.contains(id) == true
    }

    nonisolated private static func buildCodexSessionIndex(root: URL) -> CodexSessionSnapshot {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            let empty = CodexSessionSnapshot(
                builtAt: Date(), rootPath: root.standardizedFileURL.path,
                newestByCWD: [:], sessionIDsByCWD: [:]
            )
            codexSessionIndex.store(empty)
            return empty
        }

        var candidates: [(URL, Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else { continue }
            candidates.append((url, modified))
        }

        var newestByCWD: [String: (id: String, mtime: Date)] = [:]
        var sessionIDsByCWD: [String: Set<String>] = [:]
        for (url, modified) in candidates.sorted(by: { $0.1 > $1.1 }) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
            try? handle.close()
            guard let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").prefix(12) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      object["type"] as? String == "session_meta",
                      let payload = object["payload"] as? [String: Any],
                      let cwd = payload["cwd"] as? String,
                      let id = payload["id"] as? String,
                      !id.isEmpty else { continue }
                sessionIDsByCWD[cwd, default: []].insert(id)
                if newestByCWD[cwd] == nil { newestByCWD[cwd] = (id, modified) }
                break
            }
        }
        let snapshot = CodexSessionSnapshot(
            builtAt: Date(), rootPath: root.standardizedFileURL.path,
            newestByCWD: newestByCWD, sessionIDsByCWD: sessionIDsByCWD
        )
        codexSessionIndex.store(snapshot)
        return snapshot
    }
}
