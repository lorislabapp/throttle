import Foundation

/// A tiny stdio MCP server (`Throttle --mcp-server`) that lets Claude Code search
/// the user's OWN past sessions — the context its window has lost. Reuses the
/// signed app binary (no separate Node server). JSON-RPC 2.0 over newline-
/// delimited stdin/stdout, exposing one tool: `search_sessions`.
///
/// On-wedge: Throttle only PROVIDES local search; Claude's engine decides when to
/// call it. 100% local — nothing leaves the machine.
enum ThrottleMCPServer {

    static func run() {
        // Keep the FTS5 index warm (incremental; first build is the slow one).
        DispatchQueue.global(qos: .utility).async { _ = TranscriptIndex.reindex() }

        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            handle(req)
        }
    }

    private static func handle(_ req: [String: Any]) {
        let method = req["method"] as? String ?? ""
        let id = req["id"]   // nil for notifications → no response

        switch method {
        case "initialize":
            respond(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "throttle-memory", "version": "1.0.0"],
            ])
        case "tools/list":
            respond(id: id, result: ["tools": [toolSchema()]])
        case "tools/call":
            let params = req["params"] as? [String: Any]
            let args = params?["arguments"] as? [String: Any]
            let name = params?["name"] as? String ?? ""
            if name == "search_sessions", let query = args?["query"] as? String {
                respond(id: id, result: searchResult(query: query, limit: (args?["limit"] as? Int) ?? 12))
            } else {
                respond(id: id, error: [-32602, "Unknown tool or missing query"])
            }
        case "ping":
            respond(id: id, result: [:] as [String: Any])
        default:
            // Notifications (e.g. notifications/initialized) and unknown methods.
            if id != nil { respond(id: id, error: [-32601, "Method not found: \(method)"]) }
        }
    }

    private static func toolSchema() -> [String: Any] {
        [
            "name": "search_sessions",
            "description": "Search the user's PAST Claude Code sessions (their own conversation history across all projects) for context the current window has lost — e.g. an earlier decision, an error from days ago, what was tried before. Returns ranked snippets with project and date. Local full-text search; use it when you need prior context you can't see.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Keywords or a phrase to find in past sessions."],
                    "limit": ["type": "integer", "description": "Max results (default 12)."],
                ],
                "required": ["query"],
            ],
        ]
    }

    private static func searchResult(query: String, limit: Int) -> [String: Any] {
        _ = TranscriptIndex.reindex()   // cheap incremental refresh before answering
        let hits = TranscriptIndex.search(query, limit: limit)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let text: String
        if hits.isEmpty {
            text = "No matches in past sessions for \(query)."
        } else {
            text = hits.map { h in
                "• [\(h.project) · \(fmt.string(from: h.timestamp)) · \(h.role)] \(h.snippet)"
            }.joined(separator: "\n")
        }
        return ["content": [["type": "text", "text": text]]]
    }

    // MARK: - JSON-RPC framing (newline-delimited)

    private static func respond(id: Any?, result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }
    private static func respond(id: Any?, error: [Any]) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(),
               "error": ["code": error[0], "message": error[1]]])
    }
    private static func write(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
