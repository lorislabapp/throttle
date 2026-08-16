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

    var id: String { rawValue }
    var label: String { self == .claudeCode ? "Claude Code" : "Codex" }
    var shortLabel: String { self == .claudeCode ? "Claude" : "Codex" }
    var executable: String { self == .claudeCode ? "claude" : "codex" }
    var symbol: String { self == .claudeCode ? "sparkles" : "chevron.left.forwardslash.chevron.right" }
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

    static let empty = MissionHandoffContext(completed: "", remaining: "", validation: "", blockers: "")
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
