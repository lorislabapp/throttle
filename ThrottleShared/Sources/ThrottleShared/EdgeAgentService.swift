import Foundation

/// Engine for "Run sessions on your server" (BYO-server session delegation), the
/// sibling of `MCPOffloadService`. Throttle ORCHESTRATES; the user owns the box
/// (local-first / no-hosting doctrine). It GENERATES the deploy step scripts + the
/// systemd unit and VERIFIES the agent endpoint (health → authed sessions/list).
///
/// This type stays side-effect-free + testable: it never SSHes itself. Since
/// 2026-07-14 the Mac app's `EdgeDeployService` DOES run these steps over SSH
/// (one-click deploy — Kevin: "je clique offload, Throttle gère tout"); the
/// emitted full script remains as a manual fallback. The runtime API calls below
/// talk only to a deployed agent over authenticated private HTTPS; the agent is NOT
/// a data-path proxy (claude on the box reaches Anthropic directly).
///
/// Lives in `ThrottleShared` (moved from the Mac target) so both the Mac cockpit and
/// the iOS companion drive the identical networking code — it was already pure
/// Foundation, no AppKit dependency.
public enum EdgeAgentService {

    public struct SSHTarget {
        public var host: String
        public var user: String = "root"
        /// ssh identity file; nil → default agent/key. Never the key itself.
        public var keyPath: String?
        public var port: Int = 22

        public init(host: String, user: String = "root", keyPath: String? = nil, port: Int = 22) {
            self.host = host; self.user = user; self.keyPath = keyPath; self.port = port
        }
    }

    /// One remote session as reported by the agent's `/sessions`.
    public struct RemoteSession: Codable, Sendable, Identifiable, Equatable {
        public let id: String
        public let project: String
        public let cwd: String?
        public let state: String
        public let model: String?
        public let tokens: Int?
        /// Size of the transcript this session is holding on the box. A harness
        /// keeps its rollout in memory, so on a small container this is what
        /// decides survival — not the token count.
        public let transcriptBytes: Int?
        /// The box's own memory ceiling, so a transcript is judged against the
        /// machine holding it rather than a constant.
        public let memoryTotalBytes: Int?
        public let startedAt: Double?
    }

    // MARK: Deploy script (emitted as text; the user runs it — the app never SSHes)

    /// Remote Edge is HTTPS-only. Plain HTTP is accepted only for an explicit
    /// loopback development endpoint; the agent refuses non-loopback binds and
    /// expects Tailscale Serve (or an equivalent trusted proxy) to terminate TLS.
    ///
    /// A tailnet-scoped HTTP exception was tried first, when the deployed agent
    /// still bound 0.0.0.0 and every offload died as "a TLS error occurred". It
    /// was withdrawn once the agent was put behind Tailscale Serve: WireGuard
    /// already carried the traffic, but the certificate costs nothing here and
    /// leaves no plaintext path to argue about later.
    public static func remoteURL(host: String, port: Int) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let renderedHost = trimmed.contains(":") && !trimmed.hasPrefix("[")
            ? "[\(trimmed)]" : trimmed
        return "\(allowsPlainHTTP(trimmed) ? "http" : "https")://\(renderedHost):\(port)/"
    }

    /// Loopback only.
    static func allowsPlainHTTP(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
    }

    static func validatedBaseURL(_ value: String) -> URL? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else { return nil }
        if scheme == "https" { return url }
        if scheme == "http", allowsPlainHTTP(host) { return url }
        return nil
    }

    /// Pinned ttyd 1.7.7 release checksums (github.com/tsl0922/ttyd) — Debian/Ubuntu
    /// don't package ttyd at all (verified against a real Debian 12 LXC: no apt
    /// candidate), so the only sane install path is the official release binary,
    /// checksummed before it's ever executed. Covers the two arches PVE actually runs.
    static let ttydSHA256: [String: String] = [
        "x86_64": "8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55",
        "aarch64": "b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165"
    ]

    /// Displayed in the deploy step label; parsed from the bundled agent at call
    /// sites is overkill — keep in sync with `throttle-agent.mjs` VERSION.
    public static let agentVersionHint = "2.0.0"
}
