import Foundation
import Network

/// Pattern-A proxy FRONT (`Throttle --mcp-proxy <PORT> <cmd> [args]`). A minimal
/// MCP Streamable-HTTP server on 127.0.0.1:PORT that Claude Code connects to via
/// `claude mcp add --transport http throttle http://127.0.0.1:PORT/mcp`. It owns
/// the downstream stdio server through `MCPProxyChild`, so it can kill/respawn the
/// child invisibly while Claude Code keeps its stable HTTP session — the prefix
/// (and its prompt cache) never changes.
///
/// Scope: handles POST /mcp request→response as application/json (the spec allows a
/// JSON reply without SSE for simple request/response). GET (SSE) returns 405. This
/// is the MVP that proves the cache-preservation win on one server; it needs live
/// testing against Claude Code's HTTP MCP client (can't be verified headless).
enum MCPProxyServer {

    static func run(port: UInt16, downstream cmd: String, args: [String]) -> Never {
        let child = MCPProxyChild(command: cmd, args: args)
        guard child.startAndInitialize() else {
            FileHandle.standardError.write(Data("throttle --mcp-proxy: downstream init failed: \(child.lastError ?? "?")\n".utf8))
            exit(1)
        }
        child.startHealthMonitor()   // proactively respawn a zombie downstream
        let sessionId = UUID().uuidString
        let q = DispatchQueue(label: "throttle.mcpproxy.http")

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        guard let listener = try? NWListener(using: params) else {
            FileHandle.standardError.write(Data("throttle --mcp-proxy: cannot bind 127.0.0.1:\(port)\n".utf8)); exit(1)
        }
        listener.newConnectionHandler = { conn in
            conn.start(queue: q)
            serve(conn, child: child, sessionId: sessionId)
        }
        listener.start(queue: q)
        FileHandle.standardError.write(Data("throttle --mcp-proxy: listening on 127.0.0.1:\(port)/mcp → \(cmd)\n".utf8))
        dispatchMain()
    }

    // MARK: - One HTTP connection (keep-alive; one request at a time)

    private static func serve(_ conn: NWConnection, child: MCPProxyChild, sessionId: String, carry: Data = Data()) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var buffer = carry
            if let data { buffer.append(data) }

            // Need full headers first.
            guard let headerEnd = range(of: Data("\r\n\r\n".utf8), in: buffer) else {
                if isComplete || error != nil { conn.cancel() }
                else { serve(conn, child: child, sessionId: sessionId, carry: buffer) }
                return
            }
            let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
            let header = String(decoding: headerData, as: UTF8.self)
            let bodyStart = headerEnd.upperBound
            let contentLength = headerValue("content-length", in: header).flatMap { Int($0) } ?? 0
            let have = buffer.distance(from: bodyStart, to: buffer.endIndex)
            guard have >= contentLength else {                       // wait for the full body
                if isComplete || error != nil { conn.cancel() }
                else { serve(conn, child: child, sessionId: sessionId, carry: buffer) }
                return
            }
            let body = buffer.subdata(in: bodyStart..<buffer.index(bodyStart, offsetBy: contentLength))
            let leftover = buffer.subdata(in: buffer.index(bodyStart, offsetBy: contentLength)..<buffer.endIndex)

            let requestLine = header.split(separator: "\r\n").first.map(String.init) ?? ""
            let method = requestLine.split(separator: " ").first.map(String.init) ?? ""
            let response = handle(httpMethod: method, body: body, child: child, sessionId: sessionId)
            conn.send(content: response, completion: .contentProcessed { _ in
                // Keep the connection alive for the next request (MCP clients reuse it).
                serve(conn, child: child, sessionId: sessionId, carry: leftover)
            })
        }
    }

    // MARK: - Dispatch

    private static func handle(httpMethod: String, body: Data, child: MCPProxyChild, sessionId: String) -> Data {
        guard httpMethod == "POST" else { return http(204, sessionId: sessionId, json: nil) }  // GET(SSE)/DELETE: no content
        guard let req = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return http(400, sessionId: sessionId, json: ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        let id = req["id"] ?? NSNull()
        let rpc = req["method"] as? String ?? ""
        switch rpc {
        case "initialize":
            return http(200, sessionId: sessionId, json: rpcResult(id, [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "throttle-proxy", "version": "1.0.0"],
            ]))
        case "notifications/initialized":
            return http(202, sessionId: sessionId, json: nil)
        case "tools/list":
            return http(200, sessionId: sessionId, json: rpcResult(id, ["tools": child.cachedTools]))
        case "tools/call":
            let p = req["params"] as? [String: Any]
            let name = p?["name"] as? String ?? ""
            let argz = p?["arguments"] as? [String: Any] ?? [:]
            if let result = child.callTool(name: name, arguments: argz) {
                return http(200, sessionId: sessionId, json: rpcResult(id, result))
            }
            return http(200, sessionId: sessionId, json: ["jsonrpc": "2.0", "id": id,
                "error": ["code": -32603, "message": "downstream unavailable: \(child.lastError ?? "?")"]])
        case "ping":
            return http(200, sessionId: sessionId, json: rpcResult(id, [:]))
        default:
            return http(200, sessionId: sessionId, json: ["jsonrpc": "2.0", "id": id,
                "error": ["code": -32601, "message": "Method not found: \(rpc)"]])
        }
    }

    private static func rpcResult(_ id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    // MARK: - HTTP framing

    private static func http(_ status: Int, sessionId: String, json: [String: Any]?) -> Data {
        let reason = status == 200 ? "OK" : (status == 202 ? "Accepted" : (status == 204 ? "No Content" : (status == 400 ? "Bad Request" : "OK")))
        let bodyData = json.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.withoutEscapingSlashes]) } ?? Data()
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Mcp-Session-Id: \(sessionId)\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: keep-alive\r\n\r\n"
        var out = Data(head.utf8); out.append(bodyData); return out
    }

    private static func headerValue(_ name: String, in header: String) -> String? {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == name {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func range(of needle: Data, in haystack: Data) -> Range<Data.Index>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var i = haystack.startIndex
        let end = haystack.index(haystack.endIndex, offsetBy: -needle.count)
        while i <= end {
            if haystack[i..<haystack.index(i, offsetBy: needle.count)].elementsEqual(needle) {
                return i..<haystack.index(i, offsetBy: needle.count)
            }
            i = haystack.index(after: i)
        }
        return nil
    }
}
