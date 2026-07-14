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

    // Config (persisted). The token is a personal-homelab bearer secret; stored in
    // UserDefaults like the LAN peer secret — the agent should sit behind Tailscale.
    var host: String { didSet { UserDefaults.standard.set(host, forKey: "throttleEdgeHost") } }
    var port: Int { didSet { UserDefaults.standard.set(port, forKey: "throttleEdgePort") } }
    // Bearer token controls a remote session → Keychain, not UserDefaults.
    var token: String { didSet { KeychainStore.set(token, account: Self.tokenAccount) } }
    private static let tokenAccount = "edgeAgentToken"

    private(set) var sessions: [EdgeAgentService.RemoteSession] = []
    private(set) var lastVerify: EdgeAgentService.VerifyResult?
    private(set) var polling = false

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
        guard isConfigured else { return }
        if let list = try? await EdgeAgentService.sessions(baseURL: baseURL, token: token) {
            sessions = list
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

    func start(project: String?, cwd: String) async {
        guard isConfigured else { return }
        _ = try? await EdgeAgentService.start(baseURL: baseURL, token: token, project: project, cwd: cwd)
        await refresh()
    }

    func act(_ id: String, _ action: String) async {
        guard isConfigured else { return }
        try? await EdgeAgentService.action(baseURL: baseURL, token: token, id: id, action: action)
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

    /// Upload the FULL transcript of `session` to the agent for `remoteCwd`, then
    /// start a remote session resuming it — the whole point: no 10–20-turn context
    /// rebuild on the box. Full copy only; the file is streamed as-is, never trimmed.
    /// Returns the new remote session id, nil on failure (status carries the why).
    @discardableResult
    func offload(_ session: LocalSession, remoteCwd: String) async -> String? {
        guard isConfigured, !remoteCwd.isEmpty else { return nil }
        offloadStatus = "Uploading \(session.id.prefix(8))… (\(session.sizeBytes / 1024) KB)"
        do {
            let bytes = try await EdgeAgentService.uploadTranscript(
                baseURL: baseURL, token: token, remoteCwd: remoteCwd,
                sessionId: session.id, fileURL: session.path)
            offloadStatus = "Uploaded \(bytes / 1024) KB — starting remote session…"
            let remoteID = try await EdgeAgentService.start(
                baseURL: baseURL, token: token, project: session.project,
                cwd: remoteCwd, resume: session.id)
            offloadStatus = "Offloaded — resumed \(session.id.prefix(8)) on the box. It's in the cockpit rail with a REMOTE badge (click to attach)."
            await refresh()
            return remoteID
        } catch {
            offloadStatus = "Offload failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// One-click offload of a COCKPIT TAB: resolves the tab's transcript on disk
    /// and ships it, defaulting the remote cwd to /root/offload/<project>. This is
    /// the rail decision-menu path — no sheet, no picker.
    @discardableResult
    func offloadTab(sessionId: String, localCwd: String, projectName: String) async -> String? {
        let enc = MultiCockpitModel.claudeProjectDirName(localCwd)
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(enc)/\(sessionId).jsonl")
        guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            offloadStatus = "No transcript found for this session yet — say something to claude first."
            return nil
        }
        let local = LocalSession(id: sessionId, project: projectName, path: path,
                                 sizeBytes: size, modified: Date())
        return await offload(local, remoteCwd: "/root/offload/\(projectName)")
    }
}
