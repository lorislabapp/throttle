import Foundation

/// Engine for "Run sessions on your server" (BYO-server session delegation), the
/// sibling of `MCPOffloadService`. Throttle ORCHESTRATES; the user owns the box
/// (local-first / no-hosting doctrine). It GENERATES the deploy script + the systemd
/// unit and VERIFIES the agent endpoint (health → authed sessions/list) before use.
///
/// SSH execution stays the caller's job (the user runs the emitted script) — this
/// stays side-effect-free + testable and the app never SSHes. The runtime API calls
/// below talk only to an already-deployed agent over its token-gated HTTP API; the
/// agent is NOT a data-path proxy (claude on the box reaches Anthropic directly).
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
        public let startedAt: Double?
    }

    // MARK: Deploy script (emitted as text; the user runs it — the app never SSHes)

    public static func remoteURL(host: String, port: Int) -> String { "http://\(host):\(port)/" }

    /// A self-contained `#!/usr/bin/env bash` script: installs Node + tmux, writes
    /// the agent (embedded here as base64 so the script needs nothing from the repo),
    /// installs a systemd unit carrying the bearer token via an EnvironmentFile, and
    /// starts it. The user runs this — the app never SSHes.
    public static func deployScript(target: SSHTarget, token: String, httpPort: Int, agentSource: String) -> String {
        let keyOpt = target.keyPath.map { " -i \($0)" } ?? ""
        let ssh = "ssh\(keyOpt) -o BatchMode=yes -p \(target.port) \(target.user)@\(target.host)"
        let agentB64 = Data(agentSource.utf8).base64EncodedString()
        var s = "#!/usr/bin/env bash\nset -euo pipefail\n\n"
        s += "# Deploy the Throttle Edge Agent on \(target.host):\(httpPort).\n"
        s += "# 1) Node >=18 + tmux + ttyd (once):\n"
        s += "\(ssh) 'command -v node >/dev/null || (curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs); command -v tmux >/dev/null || apt-get install -y tmux; command -v ttyd >/dev/null || apt-get install -y ttyd'\n\n"
        s += "# 2) write the agent (embedded, no repo dependency):\n"
        s += "\(ssh) 'mkdir -p /opt/throttle-agent'\n"
        s += "printf %s \(shq(agentB64)) | \(ssh) 'base64 -d > /opt/throttle-agent/throttle-agent.mjs'\n\n"
        s += "# 3) token via EnvironmentFile (kept out of the unit + process list):\n"
        s += "\(ssh) 'umask 077; printf \"THROTTLE_AGENT_TOKEN=%s\\nTHROTTLE_AGENT_PORT=%s\\n\" \(shq(token)) \(httpPort) > /etc/throttle-agent.env'\n\n"
        s += "# 4) systemd unit + start:\n"
        s += "\(ssh) 'cat > /etc/systemd/system/throttle-agent.service' <<'UNIT'\n"
        s += unitText()
        s += "UNIT\n"
        s += "\(ssh) 'systemctl daemon-reload && systemctl enable --now throttle-agent && sleep 3 && systemctl is-active throttle-agent'\n\n"
        s += "# 5) back in Throttle: click Verify, then the sessions appear in the cockpit.\n"
        return s
    }

    /// The bundled agent source (`throttle-agent.mjs` in the app bundle), or nil if
    /// missing (dev builds that didn't copy the resource).
    public static func bundledAgentSource() -> String? {
        guard let url = Bundle.main.url(forResource: "throttle-agent", withExtension: "mjs"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return s
    }

    /// A fresh bearer token for a new agent.
    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
    }

    private static func unitText() -> String {
        """
        [Unit]
        Description=Throttle Edge Agent
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        EnvironmentFile=/etc/throttle-agent.env
        WorkingDirectory=/opt/throttle-agent
        ExecStart=/usr/bin/node /opt/throttle-agent/throttle-agent.mjs
        Restart=on-failure
        User=root

        [Install]
        WantedBy=multi-user.target

        """
    }

    private static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: Verify (health → authed sessions/list) — gate before wiring the cockpit

    public struct VerifyResult {
        public let ok: Bool
        public let sessionCount: Int?
        public let detail: String
        public init(ok: Bool, sessionCount: Int?, detail: String) {
            self.ok = ok; self.sessionCount = sessionCount; self.detail = detail
        }
    }

    public static func verify(baseURL: String, token: String, timeout: TimeInterval = 15) async -> VerifyResult {
        guard let base = URL(string: baseURL) else { return VerifyResult(ok: false, sessionCount: nil, detail: "Bad URL") }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: cfg)
        // 1) liveness
        do {
            let (data, resp) = try await session.data(from: base.appendingPathComponent("health"))
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["ok"] as? Bool == true else {
                return VerifyResult(ok: false, sessionCount: nil, detail: "health check failed")
            }
        } catch {
            return VerifyResult(ok: false, sessionCount: nil, detail: "unreachable: \(error.localizedDescription)")
        }
        // 2) authed endpoint — proves the token works and the API is live
        do {
            let list = try await sessions(baseURL: baseURL, token: token, timeout: timeout)
            return VerifyResult(ok: true, sessionCount: list.count, detail: "\(list.count) session(s)")
        } catch {
            return VerifyResult(ok: false, sessionCount: nil, detail: "auth/list failed: \(error.localizedDescription)")
        }
    }

    // MARK: Runtime API client (talks to an already-deployed agent)

    public enum APIError: Error { case badURL, http(Int), decode }

    public static func sessions(baseURL: String, token: String, timeout: TimeInterval = 15) async throws -> [RemoteSession] {
        let (data, _) = try await request(baseURL, "sessions", method: "GET", token: token, timeout: timeout)
        struct Wrap: Decodable { let sessions: [RemoteSession] }
        guard let wrap = try? JSONDecoder().decode(Wrap.self, from: data) else { throw APIError.decode }
        return wrap.sessions
    }

    @discardableResult
    public static func start(baseURL: String, token: String, project: String?, cwd: String, resume: String? = nil) async throws -> String {
        var body: [String: Any] = ["cwd": cwd]
        if let project { body["project"] = project }
        if let resume { body["resume"] = resume }
        let (data, _) = try await request(baseURL, "sessions", method: "POST", token: token,
                                          json: try JSONSerialization.data(withJSONObject: body))
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else { throw APIError.decode }
        return id
    }

    public static func action(baseURL: String, token: String, id: String, action: String) async throws {
        _ = try await request(baseURL, "sessions/\(id)/\(action)", method: "POST", token: token)
    }

    /// Attach a keystroke-streaming ttyd instance to session `id`. Returns the ttyd
    /// port + WS path — retargeting kills any previously attached session on the
    /// agent side (see `throttle-agent.mjs`'s single-attach model).
    public static func attach(baseURL: String, token: String, id: String) async throws -> (port: Int, path: String) {
        let (data, _) = try await request(baseURL, "sessions/\(id)/attach", method: "POST", token: token)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = obj["port"] as? Int, let path = obj["path"] as? String else { throw APIError.decode }
        return (port, path)
    }

    private static func request(_ baseURL: String, _ path: String, method: String, token: String,
                                json: Data? = nil, timeout: TimeInterval = 15) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: baseURL)?.appendingPathComponent(path) else { throw APIError.badURL }
        var r = URLRequest(url: url); r.httpMethod = method; r.timeoutInterval = timeout
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json { r.httpBody = json; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw APIError.http(-1) }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
        return (data, http)
    }
}
