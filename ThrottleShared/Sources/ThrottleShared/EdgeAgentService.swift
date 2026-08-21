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

    private static func validatedBaseURL(_ value: String) -> URL? {
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
    private static let ttydSHA256: [String: String] = [
        "x86_64": "8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55",
        "aarch64": "b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165",
    ]

    /// A self-contained `#!/usr/bin/env bash` script: installs Node + tmux + ttyd,
    /// writes the agent (embedded here as base64 so the script needs nothing from the
    /// repo), installs a systemd unit carrying the bearer token via an
    /// EnvironmentFile, and starts it. The user runs this — the app never SSHes.
    public static func deployScript(target: SSHTarget, token: String, httpPort: Int,
                                     ttydPort: Int = 8788, agentSource: String) -> String {
        let keyOpt = target.keyPath.map { " -i \($0)" } ?? ""
        let ssh = "ssh\(keyOpt) -o BatchMode=yes -p \(target.port) \(target.user)@\(target.host)"
        let agentB64 = Data(agentSource.utf8).base64EncodedString()
        let ttydChecksums = ttydSHA256.map { "\($0.value)  ttyd.\($0.key)" }.sorted().joined(separator: "\n")
        var s = "#!/usr/bin/env bash\nset -euo pipefail\n\n"
        s += "# Deploy the Throttle Edge Agent on \(target.host):\(httpPort) (ttyd on \(ttydPort)).\n"
        s += "# 1) Node >=18 + tmux (apt) + ttyd (pinned 1.7.7 release binary, checksummed before running —\n"
        s += "#    Debian/Ubuntu don't package ttyd at all, verified against a real Debian 12 LXC):\n"
        s += "\(ssh) 'command -v node >/dev/null || (curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs); command -v tmux >/dev/null || apt-get install -y tmux'\n"
        s += "\(ssh) 'bash -s' <<'INSTALL_TTYD'\n"
        s += "set -euo pipefail\n"
        s += "command -v ttyd >/dev/null && exit 0\n"
        s += "ARCH=$(uname -m)\n"
        s += "curl -fsSL -o /tmp/ttyd.$ARCH https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.$ARCH\n"
        s += "cat <<'SUMS' > /tmp/ttyd.sha256\n"
        s += ttydChecksums + "\n"
        s += "SUMS\n"
        s += "( cd /tmp && grep \"ttyd.$ARCH\\$\" ttyd.sha256 | sha256sum -c - )\n"
        s += "install -m 755 /tmp/ttyd.$ARCH /usr/local/bin/ttyd\n"
        s += "rm -f /tmp/ttyd.$ARCH /tmp/ttyd.sha256\n"
        s += "INSTALL_TTYD\n\n"
        s += "# 2) claude CLI itself, via Anthropic's native installer — NOT npm: on Debian/Ubuntu\n"
        s += "#    `apt-get install npm` drags in ~590 packages / 174MB (gcc, g++, X11 libs, eslint,\n"
        s += "#    the works, verified against a real Debian 12 LXC) just to run one binary. The\n"
        s += "#    native installer needs no Node/npm at all and stays out of the box's way:\n"
        s += "\(ssh) 'command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash'\n"
        s += "# The installer puts the binary in ~/.local/bin, which its own PATH advice (adding to\n"
        s += "# .bashrc) does NOT reach: the agent spawns claude via `bash -lc`, a login shell, which\n"
        s += "# reads .profile, not .bashrc — verified live (LXC134 needed exactly this fix; without\n"
        s += "# it every spawned session would silently fail with \"claude: command not found\").\n"
        s += "\(ssh) 'bash -s' <<'FIX_PATH'\n"
        s += "grep -q \"local/bin\" ~/.profile 2>/dev/null || cat >> ~/.profile <<'PROFILE'\n"
        s += "\n"
        s += "if [ -d \"$HOME/.local/bin\" ] ; then\n"
        s += "    PATH=\"$HOME/.local/bin:$PATH\"\n"
        s += "fi\n"
        s += "PROFILE\n"
        s += "FIX_PATH\n\n"
        s += "# 3) write the agent (embedded, no repo dependency):\n"
        s += "\(ssh) 'mkdir -p /opt/throttle-agent'\n"
        s += "printf %s \(shq(agentB64)) | \(ssh) 'base64 -d > /opt/throttle-agent/throttle-agent.mjs'\n\n"
        s += "# 4) token via a systemd credential file (not argv or process environment):\n"
        s += "\(ssh) 'umask 077; printf \"%s\\n\" \(shq(token)) > /etc/throttle-agent.token; printf \"THROTTLE_AGENT_PORT=%s\\nTHROTTLE_AGENT_TTYD_PORT=%s\\n\" \(httpPort) \(ttydPort) > /etc/throttle-agent.env'\n\n"
        s += "# 5) systemd unit + start:\n"
        s += "\(ssh) 'cat > /etc/systemd/system/throttle-agent.service' <<'UNIT'\n"
        s += unitText()
        s += "UNIT\n"
        s += "\(ssh) 'systemctl daemon-reload && systemctl enable --now throttle-agent && sleep 3 && systemctl is-active throttle-agent'\n\n"
        s += "# 6) publish the loopback-only agent through tailnet-only HTTPS. This requires\n"
        s += "#    Tailscale on the SAME host and HTTPS enabled for the tailnet. Never use Funnel.\n"
        s += "\(ssh) 'command -v tailscale >/dev/null && tailscale serve --bg --yes --https=\(httpPort) localhost:\(httpPort)'\n"
        s += "# 7) back in Throttle, use this node's full *.ts.net MagicDNS name, click Verify,\n"
        s += "#    then complete Claude authorization in the app. The token is stored in a 0600\n"
        s += "#    purpose-scoped file, never ~/.profile or a process argument.\n"
        s += "# 8) Offload with context — real sessions\n"
        s += "#    (with your Mac's transcript resumed) appear instead of the dummy.\n"
        return s
    }

    // MARK: One-click deploy — remote step bodies
    //
    // Each step is a self-contained bash script meant to be piped to
    // `ssh <target> 'bash -s'` STDIN by `EdgeDeployService`. stdin-piping (never
    // pasting into an interactive shell) sidesteps zsh history expansion — a pasted
    // `#!/usr/bin/env` line explodes as `zsh: event not found: /usr/bin/env`, which
    // is exactly how the manual copy-script path failed in the field. All steps are
    // idempotent so "Deploy" doubles as "repair".

    public struct DeployStep {
        public let label: String
        public let script: String
    }

    public static func deploySteps(token: String, httpPort: Int, ttydPort: Int = 8788,
                                   agentSource: String) -> [DeployStep] {
        let agentB64 = Data(agentSource.utf8).base64EncodedString()
        let ttydChecksums = ttydSHA256.map { "\($0.value)  ttyd.\($0.key)" }.sorted().joined(separator: "\n")
        return [
            DeployStep(label: "SSH connection", script: "set -e; echo ok-$(hostname)"),
            DeployStep(label: "Node + tmux + git", script: """
                set -euo pipefail
                command -v node >/dev/null || (curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs)
                command -v tmux >/dev/null || (apt-get update -qq && apt-get install -y tmux)
                command -v git >/dev/null || (apt-get update -qq && apt-get install -y git)
                """),
            DeployStep(label: "ttyd 1.7.7 (checksummed)", script: """
                set -euo pipefail
                command -v ttyd >/dev/null && exit 0
                ARCH=$(uname -m)
                curl -fsSL -o /tmp/ttyd.$ARCH https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.$ARCH
                cat <<'SUMS' > /tmp/ttyd.sha256
                \(ttydChecksums)
                SUMS
                ( cd /tmp && grep "ttyd.$ARCH$" ttyd.sha256 | sha256sum -c - )
                install -m 755 /tmp/ttyd.$ARCH /usr/local/bin/ttyd
                rm -f /tmp/ttyd.$ARCH /tmp/ttyd.sha256
                """),
            DeployStep(label: "claude CLI", script: """
                set -euo pipefail
                export PATH="$HOME/.local/bin:$PATH"
                command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash
                grep -q "local/bin" ~/.profile 2>/dev/null || printf '\\nif [ -d "$HOME/.local/bin" ] ; then\\n    PATH="$HOME/.local/bin:$PATH"\\nfi\\n' >> ~/.profile
                """),
            DeployStep(label: "Agent \(agentVersionHint)", script: """
                set -euo pipefail
                mkdir -p /opt/throttle-agent
                base64 -d > /opt/throttle-agent/throttle-agent.mjs <<'B64'
                \(agentB64)
                B64
                """),
            DeployStep(label: "Token + systemd unit", script: """
                set -euo pipefail
                umask 077
                printf '%s\\n' \(shq(token)) > /etc/throttle-agent.token
                printf 'THROTTLE_AGENT_PORT=%s\\nTHROTTLE_AGENT_TTYD_PORT=%s\\n' \(httpPort) \(ttydPort) > /etc/throttle-agent.env
                cat > /etc/systemd/system/throttle-agent.service <<'UNIT'
                \(unitText())UNIT
                systemctl daemon-reload
                systemctl enable --now throttle-agent
                systemctl restart throttle-agent
                sleep 2
                systemctl is-active throttle-agent
                """),
            DeployStep(label: "Tailnet HTTPS (Tailscale Serve)", script: """
                set -euo pipefail
                command -v tailscale >/dev/null || { echo 'Tailscale is required on the Edge host; refusing insecure exposure' >&2; exit 1; }
                tailscale status >/dev/null
                tailscale serve --bg --yes --https=\(httpPort) localhost:\(httpPort)
                tailscale serve status
                """),
        ]
    }

    /// Displayed in the deploy step label; parsed from the bundled agent at call
    /// sites is overkill — keep in sync with `throttle-agent.mjs` VERSION.
    public static let agentVersionHint = "1.0.0"

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
        LoadCredential=agent-token:/etc/throttle-agent.token
        Environment=HOME=/root
        WorkingDirectory=/opt/throttle-agent
        ExecStart=/usr/bin/node /opt/throttle-agent/throttle-agent.mjs
        Restart=on-failure
        User=root
        # Only kill the node process on stop/restart — NOT the whole cgroup — so
        # tmux-hosted claude sessions survive an agent restart/upgrade.
        KillMode=process
        UMask=0077
        NoNewPrivileges=true

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
        guard let base = validatedBaseURL(baseURL) else {
            return VerifyResult(ok: false, sessionCount: nil,
                                detail: "Edge requires HTTPS (HTTP is loopback-only)")
        }
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

    public struct MCPVerifyResult: Sendable {
        public let ok: Bool
        public let toolCount: Int?
        public let detail: String
        public init(ok: Bool, toolCount: Int?, detail: String) {
            self.ok = ok; self.toolCount = toolCount; self.detail = detail
        }
    }

    /// Verify the edge control plane over real MCP Streamable HTTP:
    /// initialize → initialized notification → tools/list. The bearer token is
    /// required on every request; a health-only success can never trigger a
    /// local Claude rewire.
    public static func verifyMCP(baseURL: String, token: String,
                                 timeout: TimeInterval = 20) async -> MCPVerifyResult {
        guard let url = validatedBaseURL(baseURL)?.appendingPathComponent("mcp") else {
            return .init(ok: false, toolCount: nil, detail: "Edge MCP requires HTTPS")
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config)
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"Throttle","version":"3"}}}"#
        var sessionID: String?
        do {
            let (_, response) = try await session.upload(
                for: mcpRequest(url: url, token: token),
                from: Data(initialize.utf8))
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return .init(ok: false, toolCount: nil, detail: "MCP initialize failed")
            }
            sessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id")
        } catch {
            return .init(ok: false, toolCount: nil,
                         detail: "MCP unreachable: \(error.localizedDescription)")
        }

        _ = try? await session.upload(
            for: mcpRequest(url: url, token: token, sessionID: sessionID),
            from: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        do {
            let body = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
            let (data, response) = try await session.upload(
                for: mcpRequest(url: url, token: token, sessionID: sessionID),
                from: Data(body.utf8))
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = object["result"] as? [String: Any],
                  let tools = result["tools"] as? [Any], !tools.isEmpty else {
                return .init(ok: false, toolCount: nil, detail: "MCP tools/list failed")
            }
            return .init(ok: true, toolCount: tools.count,
                         detail: "\(tools.count) edge tool(s)")
        } catch {
            return .init(ok: false, toolCount: nil,
                         detail: "MCP tools/list failed: \(error.localizedDescription)")
        }
    }

    private static func mcpRequest(url: URL, token: String,
                                   sessionID: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        return request
    }

    // MARK: Runtime API client (talks to an already-deployed agent)

    public enum APIError: Error, LocalizedError {
        case badURL, http(Int), decode
        public var errorDescription: String? {
            switch self {
            case .badURL: return "That host or port doesn't look right."
            case .http(401), .http(403): return "The agent rejected the token — re-copy it from the Mac's Edge sheet."
            case .http(404): return "The agent is up but that session no longer exists."
            case .http(let code) where code >= 500: return "The agent hit an error (HTTP \(code)). Check it on the box."
            case .http(let code): return "The agent returned HTTP \(code)."
            case .decode: return "The agent replied in a form Throttle couldn't read — version mismatch?"
            }
        }
    }

    // MARK: In-app Claude OAuth on the box (agent ≥0.4.0)

    public struct HealthInfo: Decodable, Sendable {
        public let ok: Bool
        public let version: String?
        public let claudeAuth: Bool?
        public let sessions: Int?
    }

    public static func health(baseURL: String, timeout: TimeInterval = 10) async throws -> HealthInfo {
        guard let url = validatedBaseURL(baseURL)?.appendingPathComponent("health") else { throw APIError.badURL }
        var r = URLRequest(url: url); r.timeoutInterval = timeout
        let (data, _) = try await URLSession.shared.data(for: r)
        guard let h = try? JSONDecoder().decode(HealthInfo.self, from: data) else { throw APIError.decode }
        return h
    }

    public struct AuthPeek: Decodable, Sendable {
        public let running: Bool
        public let url: String?
        public let done: Bool
    }

    public static func authStart(baseURL: String, token: String) async throws {
        _ = try await request(baseURL, "auth/start", method: "POST", token: token)
    }

    public static func authPeek(baseURL: String, token: String) async throws -> AuthPeek {
        let (data, _) = try await request(baseURL, "auth/peek", method: "GET", token: token)
        guard let p = try? JSONDecoder().decode(AuthPeek.self, from: data) else { throw APIError.decode }
        return p
    }

    public static func authSubmit(baseURL: String, token: String, code: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["code": code])
        _ = try await request(baseURL, "auth/submit", method: "POST", token: token, json: body)
    }

    public static func sessions(baseURL: String, token: String, timeout: TimeInterval = 15) async throws -> [RemoteSession] {
        let (data, _) = try await request(baseURL, "sessions", method: "GET", token: token, timeout: timeout)
        struct Wrap: Decodable { let sessions: [RemoteSession] }
        guard let wrap = try? JSONDecoder().decode(Wrap.self, from: data) else { throw APIError.decode }
        return wrap.sessions
    }

    @discardableResult
    public static func start(baseURL: String, token: String, project: String?, cwd: String,
                             resume: String? = nil, runtime: String? = nil) async throws -> String {
        var body: [String: Any] = ["cwd": cwd]
        if let project { body["project"] = project }
        if let resume { body["resume"] = resume }
        // Omitted means claude, which is what every caller predating this meant.
        if let runtime { body["runtime"] = runtime }
        let (data, _) = try await request(baseURL, "sessions", method: "POST", token: token,
                                          json: try JSONSerialization.data(withJSONObject: body))
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else { throw APIError.decode }
        return id
    }

    public static func action(baseURL: String, token: String, id: String, action: String) async throws {
        _ = try await request(baseURL, "sessions/\(id)/\(action)", method: "POST", token: token)
    }

    /// Context transfer: stream a FULL local session JSONL to the agent, which places
    /// it at `~/.claude/projects/<encoded remoteCwd>/<sessionId>.jsonl` so a follow-up
    /// `start(resume: sessionId)` resumes with the Mac session's context instead of
    /// rebuilding it (verified live 2026-07-12: `claude --resume` accepts a transcript
    /// copied from another machine/cwd). Never truncate the file — a partial JSONL
    /// corrupts the session chain.
    @discardableResult
    /// `runtime` decides where the box files the transcript. Codex stores rollouts
    /// by DATE with the timestamp baked into the filename, so its original name has
    /// to travel too — reconstructing one would put the file somewhere
    /// `codex resume` never looks.
    public static func uploadTranscript(baseURL: String, token: String, remoteCwd: String,
                                        sessionId: String, fileURL: URL,
                                        runtime: String? = nil,
                                        timeout: TimeInterval = 120) async throws -> Int {
        guard validatedBaseURL(baseURL) != nil else { throw APIError.badURL }
        var comps = URLComponents(string: baseURL)
        comps?.path = "/transcripts"
        var items = [URLQueryItem(name: "cwd", value: remoteCwd),
                     URLQueryItem(name: "session", value: sessionId)]
        if let runtime {
            items.append(URLQueryItem(name: "runtime", value: runtime))
            if runtime == "codex" {
                items.append(URLQueryItem(name: "file", value: fileURL.lastPathComponent))
            }
        }
        comps?.queryItems = items
        guard let url = comps?.url else { throw APIError.badURL }
        var r = URLRequest(url: url); r.httpMethod = "PUT"; r.timeoutInterval = timeout
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: r, fromFile: fileURL)
        guard let http = resp as? HTTPURLResponse else { throw APIError.http(-1) }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bytes = obj["bytes"] as? Int else { throw APIError.decode }
        return bytes
    }

    /// Repo transfer: upload a `git bundle` for the agent to clone at `remoteCwd`
    /// (409 = cwd already has content; caller treats that as non-fatal).
    @discardableResult
    /// Pull the box's repository back as a git bundle.
    ///
    /// Returns the bundle on disk and, when the box had uncommitted work, the
    /// commit that captured it. The caller fetches from the bundle into refs of
    /// its own choosing — this deliberately does not decide where the commits
    /// land, because that decision can destroy work and does not belong to a
    /// transport function.
    public static func downloadRepoBundle(baseURL: String, token: String, remoteCwd: String,
                                          timeout: TimeInterval = 300)
        async throws -> (fileURL: URL, wipCommit: String?) {
        guard validatedBaseURL(baseURL) != nil else { throw APIError.badURL }
        var comps = URLComponents(string: baseURL)
        comps?.path = "/repos"
        comps?.queryItems = [URLQueryItem(name: "cwd", value: remoteCwd)]
        guard let url = comps?.url else { throw APIError.badURL }
        var r = URLRequest(url: url); r.httpMethod = "GET"; r.timeoutInterval = timeout
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (temp, resp) = try await URLSession.shared.download(for: r)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("throttle-edge-\(UUID().uuidString).bundle")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        let wip = http.value(forHTTPHeaderField: "x-throttle-wip")
        return (dest, (wip?.isEmpty == false) ? wip : nil)
    }

    public static func uploadRepoBundle(baseURL: String, token: String, remoteCwd: String,
                                        branch: String, fileURL: URL,
                                        timeout: TimeInterval = 300) async throws -> Bool {
        guard validatedBaseURL(baseURL) != nil else { throw APIError.badURL }
        var comps = URLComponents(string: baseURL)
        comps?.path = "/repos"
        comps?.queryItems = [URLQueryItem(name: "cwd", value: remoteCwd),
                             URLQueryItem(name: "branch", value: branch)]
        guard let url = comps?.url else { throw APIError.badURL }
        var r = URLRequest(url: url); r.httpMethod = "PUT"; r.timeoutInterval = timeout
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, resp) = try await URLSession.shared.upload(for: r, fromFile: fileURL)
        guard let http = resp as? HTTPURLResponse else { throw APIError.http(-1) }
        if http.statusCode == 409 { return false }   // cwd not empty — repo already there
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
        return true
    }

    /// Bring-back: download the NEWEST transcript for remote session `id` (the box
    /// writes a fresh jsonl per resume, so the current one — not the originally
    /// uploaded id — is returned). Returns (sessionId, jsonl bytes).
    public static func downloadTranscript(baseURL: String, token: String, id: String,
                                          timeout: TimeInterval = 120) async throws -> (sessionId: String, data: Data) {
        let (data, http) = try await request(baseURL, "sessions/\(id)/transcript",
                                             method: "GET", token: token, timeout: timeout)
        guard let sid = http.value(forHTTPHeaderField: "X-Session-Id"), !sid.isEmpty else {
            throw APIError.decode
        }
        return (sid, data)
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
        guard let url = validatedBaseURL(baseURL)?.appendingPathComponent(path) else { throw APIError.badURL }
        var r = URLRequest(url: url); r.httpMethod = method; r.timeoutInterval = timeout
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json { r.httpBody = json; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw APIError.http(-1) }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
        return (data, http)
    }
}
