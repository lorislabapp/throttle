import Foundation
import SwiftUI
import ThrottleShared

/// Holds the connection to a deployed Throttle Edge Agent and its live session list.
///
/// Deliberately SEPARATE from `MultiCockpitModel` (the local cockpit): remote
/// sessions are surfaced in their own panel rather than merged into the local
/// `sessions` array, so this feature can't destabilise the core cockpit. Lifecycle
/// (start/stop/pause/resume) via `EdgeAgentService`; keystroke streaming (the
/// `attach` route) is the iOS companion's job — see `EdgeTerminalView` — not wired
/// into this Mac-side panel.
@MainActor
@Observable
final class RemoteSessionsService {
    static let shared = RemoteSessionsService()

    // Config (persisted). Non-loopback endpoints resolve to HTTPS and the agent
    // itself refuses public binds; the bearer secret is stored in Keychain.
    var host: String { didSet { UserDefaults.standard.set(host, forKey: "throttleEdgeHost") } }
    var port: Int { didSet { UserDefaults.standard.set(port, forKey: "throttleEdgePort") } }
    // Bearer token controls a remote session → Keychain, not UserDefaults.
    var token: String { didSet { KeychainStore.set(token, account: Self.tokenAccount) } }
    private static let tokenAccount = "edgeAgentToken"
    /// Above this, moving a session to the box is a way to lose it. Set below the
    /// 275 MB that was actually killed there, not at it.
    static let transcriptOffloadLimit = 128 * 1024 * 1024

    private(set) var sessions: [EdgeAgentService.RemoteSession] = []
    private(set) var lastVerify: EdgeAgentService.VerifyResult?
    private(set) var polling = false

    var isStartingSession = false
    var pendingStart: EdgeFreshSessionStarter.Pending?
    var startRecoveryError: String?

    private var pollTask: Task<Void, Never>?

    var baseURL: String { EdgeAgentService.remoteURL(host: host, port: port) }
    var isConfigured: Bool { !host.isEmpty && !token.isEmpty }

    private init() {
        host = UserDefaults.standard.string(forKey: "throttleEdgeHost") ?? ""
        let p = UserDefaults.standard.integer(forKey: "throttleEdgePort")
        port = p == 0 ? 8787 : p
        if let k = KeychainStore.get(account: Self.tokenAccount) {
            token = k
        } else if let legacy = UserDefaults.standard.string(forKey: "throttleEdgeToken"), !legacy.isEmpty {
            token = legacy
            KeychainStore.set(legacy, account: Self.tokenAccount)
            UserDefaults.standard.removeObject(forKey: "throttleEdgeToken")
        } else {
            token = ""
        }
    }

    func verify() async {
        guard isConfigured else { lastVerify = .init(ok: false, sessionCount: nil, detail: "Set host + token"); return }
        lastVerify = await EdgeAgentService.verify(baseURL: baseURL, token: token)
    }

    func refresh() async {
        await refreshPendingStart()
        guard isConfigured else { return }
        if let list = try? await EdgeAgentService.sessions(baseURL: baseURL, token: token) {
            // A session that stops appearing has ended on the box, and the row
            // simply vanishing is the worst way to learn it: measured 2026-08-22,
            // a session was OOM-killed there and the only signal was a rail that
            // was one line shorter than before. Announce the disappearance.
            let goneIDs = Set(sessions.map(\.id)).subtracting(list.map(\.id))
            let gone = sessions.filter { goneIDs.contains($0.id) }
            sessions = list
            for session in gone { onSessionVanished?(session) }
            warnOnTranscriptGrowth(list)
        }
    }

    /// Raised when a remote session the app was tracking is no longer reported by
    /// the box. `nil` until the cockpit wires a notification to it.
    var onSessionVanished: ((EdgeAgentService.RemoteSession) -> Void)?

    /// Raised once per session when its transcript grows past a share of the
    /// box's memory. `nil` until the cockpit wires a notification to it.
    var onTranscriptTooLarge: ((EdgeAgentService.RemoteSession, String) -> Void)?
    private var warnedTranscripts: Set<String> = []

    /// Warn while the session can still be saved.
    ///
    /// The guard at offload time only covers sessions being moved. The one that
    /// died on 2026-08-22 was already on the box and grew there: its rollout
    /// reached 275 MB against 2 GB of container memory, and nothing watched it.
    /// The threshold is a fraction of the box's actual memory rather than a fixed
    /// size, because the same transcript is harmless on a large machine.
    private func warnOnTranscriptGrowth(_ list: [EdgeAgentService.RemoteSession]) {
        for session in list {
            guard let bytes = session.transcriptBytes, bytes > 0 else { continue }
            let total = session.memoryTotalBytes ?? (2 * 1024 * 1024 * 1024)
            // An eighth of the box's memory: the session that died was at roughly
            // that mark twenty minutes before the kill, which is enough warning
            // to finish a thought and start fresh.
            guard bytes >= total / 8 else {
                warnedTranscripts.remove(session.id)   // shrank or restarted
                continue
            }
            guard !warnedTranscripts.contains(session.id) else { continue }
            warnedTranscripts.insert(session.id)
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            let cap = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .memory)
            onTranscriptTooLarge?(session,
                "Its transcript has reached \(size) on a box with \(cap). A harness holds that in "
                + "memory: a session was killed here at 275 MB on 2026-08-22. Finish the thought and "
                + "start a fresh session — the code stays where it is.")
        }
    }

    /// Poll every 10 s while the panel is visible / feature is on.
    func startPolling() {
        guard isConfigured, !polling else { return }
        polling = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func stopPolling() { pollTask?.cancel(); pollTask = nil; polling = false }

    /// `runtime` is "claude" or "codex". The box launches a different binary and
    /// resumes with a different flag for each, so the choice cannot be inferred
    /// afterwards — it has to travel with the request.
    func start(project: String?, cwd: String, runtime: String = "claude") async {
        guard isConfigured, !isStartingSession else { return }
        isStartingSession = true
        defer { isStartingSession = false }
        offloadStatus = "Starting a new conversation on the server…"
        do {
            _ = try await EdgeAgentService.start(baseURL: baseURL, token: token, project: project,
                                                 cwd: cwd, runtime: runtime)
            offloadStatus = "Conversation started on the server."
        } catch {
            offloadStatus =
                "Start is unresolved. Its saved request will be reused: \(error.localizedDescription)"
        }
        await refresh()
    }

    func act(_ id: String, _ action: String) async {
        guard isConfigured else { return }
        do {
            try await EdgeAgentService.action(baseURL: baseURL, token: token, id: id, action: action)
        } catch {
            offloadStatus = "Server action is unresolved: \(error.localizedDescription)"
        }
        await refresh()
    }

    // MARK: Context transfer (offload a local session WITH its transcript)

    /// A local Claude Code session eligible for offload: the JSONL transcript on
    /// this Mac, identified by its filename stem.
    struct LocalSession: Identifiable, Equatable {
        let id: String          // session id = JSONL filename stem
        let project: String     // decoded-ish project dir name (display only)
        let path: URL
        let sizeBytes: Int
        let modified: Date
    }

    /// Offload progress/result line — shown in the sheet AND the cockpit rail.
    /// Settable by the rail's direct-offload path for its guard messages.
    var offloadStatus: String?

    /// Newest local transcripts across `~/.claude/projects/` (display picker feed).
    /// Pure filesystem scan — no DB dependency, safe to call from the sheet.
    static func recentLocalSessions(limit: Int = 12) -> [LocalSession] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        var all: [LocalSession] = []
        for proj in projects {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: proj, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                let vals = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                all.append(LocalSession(
                    id: f.deletingPathExtension().lastPathComponent,
                    project: proj.lastPathComponent,
                    path: f,
                    sizeBytes: vals?.fileSize ?? 0,
                    modified: vals?.contentModificationDate ?? .distantPast))
            }
        }
        return Array(all.sorted { $0.modified > $1.modified }.prefix(limit))
    }

    /// Transfer only a conversation controlled by a known cockpit tab. A recent
    /// file alone cannot prove that its native writer has been stopped.
    @discardableResult
    func offload(_ local: LocalSession) async -> String? {
        let model = MultiCockpitModel.shared
        let matches = model.sessions.filter { tab in
            guard tab.runtime == .claudeCode,
                  tab.sessionId?.caseInsensitiveCompare(local.id) == .orderedSame,
                  let bound = NativeSessionBinding.knownTranscript(
                    runtime: tab.runtime, id: local.id, cwd: tab.cwd, codexURLs: []) else { return false }
            return bound.url.resolvingSymlinksInPath() == local.path.resolvingSymlinksInPath()
        }
        guard matches.count == 1, let tab = matches.first, !model.isQuitting, !tab.isTransitioning else {
            offloadStatus = "Open this conversation in Cockpit first so Throttle can stop and transfer it safely."
            return nil
        }
        tab.isTransferring = true
        defer { tab.isTransferring = false; model.persist() }
        return await transferToServer(tab)
    }

    /// What this project can do here that it will not be able to do on the box.
    ///
    /// Counted from the MCP servers configured for the project, plus the local
    /// credential-bound work that cannot move at all — signing, notarisation and
    /// App Store submission need the login keychain and the Apple key, and those
    /// are not things to copy onto a server because a session asked.
    static func capabilitiesLostOnOffload(localCwd: String) -> String {
        var lost: [String] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var names = Set((root["mcpServers"] as? [String: Any])?.keys.map { $0 } ?? [])
            if let projects = root["projects"] as? [String: Any],
               let mine = projects[localCwd] as? [String: Any],
               let scoped = mine["mcpServers"] as? [String: Any] {
                names.formUnion(scoped.keys)
            }
            // Present on the box already — see the agent's own MCP config.
            names.subtract(["proxmox", "opnsense-mcp"])
            if !names.isEmpty {
                lost.append("\(names.count) MCP server\(names.count == 1 ? "" : "s")")
            }
        }
        if FileManager.default.fileExists(atPath: localCwd + "/project.yml")
            || !((try? FileManager.default.contentsOfDirectory(atPath: localCwd))?
                .filter { $0.hasSuffix(".xcodeproj") }.isEmpty ?? true) {
            lost.append("signing and App Store submission")
        }
        return lost.joined(separator: " and ")
    }

}
