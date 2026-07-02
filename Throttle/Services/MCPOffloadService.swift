import Foundation

/// Engine for "Run MCP on your server" (BYO-server offload). Throttle ORCHESTRATES;
/// the user owns the box (local-first / no-hosting doctrine). This service is the
/// pure logic proven manually during the 2026-07-02 offload:
///   • generate the Supergateway systemd unit (`--stateful`, Streamable HTTP),
///   • generate the deploy plan (copy local code, npm install, place secrets),
///   • VERIFY an endpoint end-to-end over Streamable HTTP (initialize →
///     tools/list) BEFORE rewiring — gate on tools, not just /healthz.
///
/// SSH execution + `~/.claude.json` rewrite are done by the caller (the app),
/// not here; this stays side-effect-free + testable.
enum MCPOffloadService {

    struct SSHTarget: Codable, Hashable, Sendable {
        var host: String          // hostname or IP reachable from the Mac (LAN/Tailscale)
        var user: String          // ssh user
        var keyPath: String?      // ssh identity file; nil → default agent/key. Never the key itself.
        var port: Int = 22
    }

    /// A ready-to-run gateway definition for one MCP server on the remote host.
    struct GatewayUnit: Sendable {
        let name: String          // service name suffix → mcp-<name>
        let httpPort: Int         // exposed Streamable HTTP port
        let workingDir: String    // where the server code lives on the host
        let stdioCommand: String  // e.g. "npx -y tavily-mcp" or "node index.js"
        let envFile: String?      // /etc/mcp-gateway/<name>.env, or nil
        var nodePath: String = "/usr/lib/node_modules"   // so pino-pretty-style transports resolve

        var serviceName: String { "mcp-\(name)" }

        /// systemd unit text — mirrors the units deployed on mcp-gateway (LXC 131).
        var unitText: String {
            let envLine = envFile.map { "EnvironmentFile=\($0)\n" } ?? ""
            return """
            [Unit]
            Description=MCP gateway: \(name) (Supergateway to Streamable HTTP)
            After=network-online.target
            Wants=network-online.target
            [Service]
            Environment=NODE_PATH=\(nodePath)
            \(envLine)WorkingDirectory=\(workingDir)
            ExecStart=/usr/bin/supergateway --stdio "\(stdioCommand)" --outputTransport streamableHttp --port \(httpPort) --streamableHttpPath /mcp --stateful --healthEndpoint /healthz
            Restart=on-failure
            RestartSec=5
            User=root
            [Install]
            WantedBy=multi-user.target
            """
        }
    }

    static func remoteURL(host: String, port: Int) -> String { "http://\(host):\(port)/mcp" }

    /// The `claude mcp` rewire commands the caller (or the user) runs. Emitted as
    /// text because editing `~/.claude.json` is the app's/user's job, not this
    /// side-effect-free engine's.
    static func rewireCommands(name: String, url: String) -> [String] {
        ["claude mcp remove \(name) -s local",
         "claude mcp remove \(name) -s user",
         "claude mcp add -s user --transport http \(name) \(url)"]
    }

    // MARK: - Verify (Streamable HTTP: initialize → tools/list)

    struct VerifyResult: Sendable {
        let ok: Bool
        let toolCount: Int?
        let detail: String
    }

    /// End-to-end check of a remote MCP endpoint the way Claude Code drives it:
    /// initialize (capture Mcp-Session-Id) → notifications/initialized →
    /// tools/list. Returns ok only if tools/list yields a tools array — the gate
    /// that catches "healthz ok but child broken" (missing pino-pretty, bad creds,
    /// stateless-session drops, …).
    static func verify(urlString: String, timeout: TimeInterval = 30) async -> VerifyResult {
        guard let url = URL(string: urlString) else {
            return VerifyResult(ok: false, toolCount: nil, detail: "Bad URL")
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: cfg)

        let initBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"Throttle","version":"1"}}}"#
        var sid: String?
        do {
            let (_, resp) = try await session.upload(for: post(url), from: Data(initBody.utf8))
            guard let http = resp as? HTTPURLResponse else {
                return VerifyResult(ok: false, toolCount: nil, detail: "No HTTP response")
            }
            // Mcp-Session-Id header (case-insensitive lookup).
            sid = http.value(forHTTPHeaderField: "Mcp-Session-Id")
                ?? http.value(forHTTPHeaderField: "mcp-session-id")
            guard (200..<300).contains(http.statusCode) else {
                return VerifyResult(ok: false, toolCount: nil, detail: "initialize HTTP \(http.statusCode)")
            }
        } catch {
            return VerifyResult(ok: false, toolCount: nil, detail: "initialize failed: \(error.localizedDescription)")
        }

        // notifications/initialized (best-effort) + tools/list, carrying the session.
        _ = try? await session.upload(for: post(url, session: sid),
                                      from: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        do {
            let listBody = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
            let (data, resp) = try await session.upload(for: post(url, session: sid), from: Data(listBody.utf8))
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return VerifyResult(ok: false, toolCount: nil, detail: "tools/list HTTP error")
            }
            guard let json = firstJSONObject(in: data),
                  let result = json["result"] as? [String: Any],
                  let tools = result["tools"] as? [Any] else {
                return VerifyResult(ok: false, toolCount: nil, detail: "tools/list returned no tools")
            }
            return VerifyResult(ok: true, toolCount: tools.count, detail: "\(tools.count) tools")
        } catch {
            return VerifyResult(ok: false, toolCount: nil, detail: "tools/list failed: \(error.localizedDescription)")
        }
    }

    private static func post(_ url: URL, session: String? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let session { r.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        return r
    }

    /// The body may be plain JSON or an SSE stream (`event: message\ndata: {…}`).
    /// Return the first parseable JSON object found.
    private static func firstJSONObject(in data: Data) -> [String: Any]? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return obj }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let s = line.hasPrefix("data:") ? line.dropFirst(5).trimmingCharacters(in: .whitespaces) : String(line)
            if let d = s.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return obj }
        }
        return nil
    }
}
