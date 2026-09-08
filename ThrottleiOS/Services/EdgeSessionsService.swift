import Foundation
import Network
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
    // The bearer token can control a remote session → Keychain, not UserDefaults.
    var token: String { didSet { KeychainStore.set(token, account: Self.tokenAccount) } }
    private static let tokenAccount = "edgeAgentToken"

    private(set) var sessions: [EdgeAgentService.RemoteSession] = []
    private(set) var lastVerify: EdgeAgentService.VerifyResult?

    /// Whether the agent is currently reachable, so the list can show a truthful
    /// staleness badge instead of rendering the last-good sessions as if live.
    enum Reachability { case unknown, live, unreachable }
    private(set) var reachability: Reachability = .unknown

    private var pollTask: Task<Void, Never>?
    private var backoff: UInt64 = 10  // seconds, grows to a cap on repeated failure

    // Reachability gate: skip polling a dead endpoint while the device is offline
    // (saves radio wakeups), and re-poll immediately on the offline→online edge.
    private let pathMonitor = NWPathMonitor()
    private var online = true

    var baseURL: String { EdgeAgentService.remoteURL(host: host, port: port) }
    var isConfigured: Bool { !host.isEmpty && !token.isEmpty }

    private init() {
        host = UserDefaults.standard.string(forKey: "throttleEdgeHost") ?? ""
        let p = UserDefaults.standard.integer(forKey: "throttleEdgePort")
        port = p == 0 ? 8787 : p
        // Prefer Keychain; one-time migrate any legacy plaintext token out of
        // UserDefaults so it isn't left behind on disk.
        if let k = KeychainStore.get(account: Self.tokenAccount) {
            token = k
        } else if let legacy = UserDefaults.standard.string(forKey: "throttleEdgeToken"), !legacy.isEmpty {
            token = legacy
            KeychainStore.set(legacy, account: Self.tokenAccount)
            UserDefaults.standard.removeObject(forKey: "throttleEdgeToken")
        } else {
            token = ""
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let up = path.status == .satisfied
                let cameOnline = up && !self.online
                self.online = up
                if cameOnline { await self.refresh() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "throttle.edge.path"))
    }

    func verify() async {
        guard isConfigured else { lastVerify = .init(ok: false, sessionCount: nil, detail: "Set host + token"); return }
        lastVerify = await EdgeAgentService.verify(baseURL: baseURL, token: token)
    }

    @discardableResult
    func refresh() async -> Bool {
        guard isConfigured else { return false }
        do {
            sessions = try await EdgeAgentService.sessions(baseURL: baseURL, token: token)
            reachability = .live
            return true
        } catch {
            reachability = .unreachable
            return false
        }
    }

    /// Poll while visible. On success poll every 10s; on failure back off
    /// (10→20→40→…→120s cap) so a dead/unreachable agent doesn't wake the radio
    /// every 10s and drain the battery. Resets to 10s the moment it recovers.
    func startPolling() {
        guard isConfigured, pollTask == nil else { return }
        backoff = 10
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                if self?.online ?? true {
                    let ok = await self?.refresh() ?? false
                    if let self { self.backoff = ok ? 10 : min(self.backoff * 2, 120) }
                }
                try? await Task.sleep(nanoseconds: (self?.backoff ?? 10) * 1_000_000_000)
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
    private(set) var pendingStart: EdgeFreshSessionStarter.Pending?
    private(set) var startRecoveryError: String?

    /// Start a fresh conversation, retaining uncertain requests across app restarts.
    @discardableResult
    func start(cwd: String) async -> Bool {
        guard isConfigured, !cwd.isEmpty else { return false }
        actionStatus = "Starting session…"
        do {
            _ = try await EdgeAgentService.start(baseURL: baseURL, token: token, project: nil, cwd: cwd)
            actionStatus = nil
            await refreshPendingStart()
            await refresh()
            return true
        } catch {
            actionStatus = "Start is unresolved: \(error.localizedDescription)"
            await refreshPendingStart()
            return false
        }
    }

    func refreshPendingStart() async {
        do {
            pendingStart = try await EdgeFreshSessionStarter.shared.pending()
            startRecoveryError = nil
        } catch { startRecoveryError = error.localizedDescription }
    }

    func resolvePendingStart(stop: Bool) async {
        guard isConfigured else { return }
        do {
            if stop {
                try await EdgeFreshSessionStarter.shared.stopPending(endpoint: baseURL, token: token)
                actionStatus = "The original server start is stopped."
            } else {
                _ = try await EdgeFreshSessionStarter.shared.retry(endpoint: baseURL, token: token)
                actionStatus = "The original conversation is confirmed on the server."
            }
        } catch { actionStatus = "Server start needs recovery: \(error.localizedDescription)" }
        await refreshPendingStart()
        await refresh()
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
