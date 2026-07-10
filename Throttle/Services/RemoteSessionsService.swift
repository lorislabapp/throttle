import Foundation
import SwiftUI

/// Holds the connection to a deployed Throttle Edge Agent and its live session list.
///
/// Deliberately SEPARATE from `MultiCockpitModel` (the local cockpit): remote
/// sessions are surfaced in their own panel rather than merged into the local
/// `sessions` array, so this feature can't destabilise the core cockpit. Measure +
/// coarse lifecycle only (start/stop/pause/resume via `EdgeAgentService`) — no
/// keystroke path (measure-only / cockpit-not-engine).
@MainActor
@Observable
final class RemoteSessionsService {
    static let shared = RemoteSessionsService()

    // Config (persisted). The token is a personal-homelab bearer secret; stored in
    // UserDefaults like the LAN peer secret — the agent should sit behind Tailscale.
    var host: String { didSet { UserDefaults.standard.set(host, forKey: "throttleEdgeHost") } }
    var port: Int { didSet { UserDefaults.standard.set(port, forKey: "throttleEdgePort") } }
    var token: String { didSet { UserDefaults.standard.set(token, forKey: "throttleEdgeToken") } }

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
}
