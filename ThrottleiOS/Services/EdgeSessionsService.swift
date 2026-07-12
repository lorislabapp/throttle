import Foundation
import ThrottleShared

/// iOS counterpart to the Mac's `RemoteSessionsService`: holds the connection to a
/// Throttle Edge Agent (deployed from the Mac — this app never deploys or SSHes)
/// and polls its live session list. Deliberately separate from `MirrorStore` (the
/// CloudKit mirror of the Mac's own cockpit) — an edge-agent session is a different
/// thing entirely, hosted on whatever box the agent runs on.
@MainActor
@Observable
final class EdgeSessionsService {
    static let shared = EdgeSessionsService()

    var host: String { didSet { UserDefaults.standard.set(host, forKey: "throttleEdgeHost") } }
    var port: Int { didSet { UserDefaults.standard.set(port, forKey: "throttleEdgePort") } }
    var token: String { didSet { UserDefaults.standard.set(token, forKey: "throttleEdgeToken") } }

    private(set) var sessions: [EdgeAgentService.RemoteSession] = []
    private(set) var lastVerify: EdgeAgentService.VerifyResult?

    private var pollTask: Task<Void, Never>?

    var baseURL: String { EdgeAgentService.remoteURL(host: host, port: port) }
    var isConfigured: Bool { !host.isEmpty && !token.isEmpty }

    private init() {
        host = UserDefaults.standard.string(forKey: "throttleEdgeHost") ?? ""
        let p = UserDefaults.standard.integer(forKey: "throttleEdgePort")
        port = p == 0 ? 8787 : p
        token = UserDefaults.standard.string(forKey: "throttleEdgeToken") ?? ""
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

    /// Poll every 10s while the panel is visible.
    func startPolling() {
        guard isConfigured, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func stopPolling() { pollTask?.cancel(); pollTask = nil }

    /// Ask the agent to (re)attach a keystroke-streaming ttyd for this session, and
    /// return where to reach it. Retargets away from any previously attached session.
    func attach(id: String) async throws -> (port: Int, path: String) {
        try await EdgeAgentService.attach(baseURL: baseURL, token: token, id: id)
    }

    /// Transient status line surfaced by the Edge UI after an action.
    private(set) var actionStatus: String?

    /// Start a remote session on the agent. `resume` (a session id already present on
    /// the box — e.g. one the Mac offloaded with its transcript) resumes that
    /// conversation instead of a fresh one: the iOS half of "offload with context".
    /// The transcript UPLOAD itself stays Mac-origin (that's where the JSONL lives);
    /// here we only ask the box to resume an id it already has.
    @discardableResult
    func start(cwd: String, resume: String? = nil) async -> Bool {
        guard isConfigured, !cwd.isEmpty else { return false }
        actionStatus = resume == nil ? "Starting session…" : "Resuming \(resume!.prefix(8))…"
        do {
            _ = try await EdgeAgentService.start(baseURL: baseURL, token: token,
                                                 project: nil, cwd: cwd, resume: resume)
            actionStatus = nil
            await refresh()
            return true
        } catch {
            actionStatus = "Start failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Coarse lifecycle: pause / resume / stop a running session.
    func act(_ id: String, _ action: String) async {
        guard isConfigured else { return }
        do {
            try await EdgeAgentService.action(baseURL: baseURL, token: token, id: id, action: action)
            await refresh()
        } catch {
            actionStatus = "\(action.capitalized) failed: \(error.localizedDescription)"
        }
    }
}
