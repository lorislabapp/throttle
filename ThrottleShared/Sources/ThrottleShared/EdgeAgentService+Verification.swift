import Foundation

extension EdgeAgentService {

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
    public static func verifyMCP(
        baseURL: String, token: String,
        timeout: TimeInterval = 20
    ) async -> MCPVerifyResult {
        guard let url = validatedBaseURL(baseURL)?.appendingPathComponent("mcp") else {
            return .init(ok: false, toolCount: nil, detail: "Edge MCP requires HTTPS")
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config)
        let initialize =
            #"""
            {"jsonrpc":"2.0","id":1,"method":"initialize",\#
            "params":{"protocolVersion":"2024-11-05","capabilities":{},\#
            "clientInfo":{"name":"Throttle","version":"3"}}}
            """#
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

    static func mcpRequest(
        url: URL, token: String,
        sessionID: String? = nil
    ) -> URLRequest {
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
}
