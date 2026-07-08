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
            var tools = [searchSchema(), budgetSchema(), costSchema(), deadSkillsSchema(), mcpHealthSchema(), expandPointerSchema(), recallSchema(), semanticSearchSchema()]
            // web_render is opt-in: only advertised when the user enabled Web
            // research, so a disabled capability costs zero schema tokens.
            if UserDefaults.standard.bool(forKey: "throttleWebEnabled") { tools.append(webRenderSchema()) }
            respond(id: id, result: ["tools": tools])
        case "tools/call":
            let params = req["params"] as? [String: Any]
            let args = params?["arguments"] as? [String: Any]
            let name = params?["name"] as? String ?? ""
            switch name {
            case "search_sessions":
                if let query = args?["query"] as? String {
                    respond(id: id, result: searchResult(query: query, limit: (args?["limit"] as? Int) ?? 12))
                } else {
                    respond(id: id, error: [-32602, "Missing query"])
                }
            case "get_budget_headroom":
                respond(id: id, result: textResult(budgetText()))
            case "get_session_cost":
                respond(id: id, result: textResult(costText()))
            case "get_dead_skills":
                respond(id: id, result: textResult(deadSkillsText()))
            case "get_mcp_health_status":
                respond(id: id, result: textResult(mcpHealthText()))
            case "throttle_expand_pointer":
                if let hash = args?["hash"] as? String {
                    respond(id: id, result: textResult(expandPointerText(hash)))
                } else {
                    respond(id: id, error: [-32602, "Missing hash"])
                }
            case "throttle_recall":
                if let topic = args?["topic"] as? String {
                    respond(id: id, result: textResult(recallText(topic: topic, scope: args?["scope"] as? String ?? "")))
                } else {
                    respond(id: id, error: [-32602, "Missing topic"])
                }
            case "throttle_semantic_search":
                if let query = args?["query"] as? String {
                    respond(id: id, result: textResult(semanticSearchText(query: query, repo: args?["repo"] as? String, k: (args?["k"] as? Int) ?? 6)))
                } else {
                    respond(id: id, error: [-32602, "Missing query"])
                }
            case "web_render":
                if let url = args?["url"] as? String {
                    respond(id: id, result: textResult(WebRenderClient.render(
                        url: url, wait: args?["wait"] as? String, waitSelector: args?["waitSelector"] as? String,
                        maxChars: args?["maxChars"] as? Int, timeoutMs: args?["timeoutMs"] as? Int)))
                } else {
                    respond(id: id, error: [-32602, "Missing url"])
                }
            default:
                respond(id: id, error: [-32602, "Unknown tool: \(name)"])
            }
        case "ping":
            respond(id: id, result: [:] as [String: Any])
        default:
            // Notifications (e.g. notifications/initialized) and unknown methods.
            if id != nil { respond(id: id, error: [-32601, "Method not found: \(method)"]) }
        }
    }

    private static func searchSchema() -> [String: Any] {
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

    private static func budgetSchema() -> [String: Any] {
        [
            "name": "get_budget_headroom",
            "description": "How much Claude Code usage budget the user has left RIGHT NOW: the 5-hour rolling cap and the 7-day cap, as % used and % headroom remaining. Call this before starting an expensive task, or when the user asks 'how much do I have left' / 'am I close to the cap'. Read-only; reflects what Throttle's meter currently shows.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ]
    }

    private static func costSchema() -> [String: Any] {
        [
            "name": "get_session_cost",
            "description": "The user's recent Claude Code token spend and reference cost (last 7 days, weighted tokens + ≈EUR at developer-API rates), plus tokens Throttle's optimizations saved. A reference figure, not the user's actual subscription bill. Use when the user asks what their work is costing or how much Throttle is saving.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ]
    }

    // MARK: - Budget / cost (read the same snapshot the menu bar shows)

    /// nil when the snapshot is missing or stale (app not running / not recomputed
    /// lately) — we report that honestly instead of a stale number (golden rule).
    private static func freshSnapshot() -> ThrottleIntentSnapshot? {
        let s = ThrottleIntentSnapshotStore.read()
        let age = Date().timeIntervalSince(s.computedAt)
        guard s.computedAt != .distantPast, age < 600 else { return nil }
        return s
    }

    private static func ago(_ d: Date) -> String {
        let s = Int(max(0, Date().timeIntervalSince(d)))
        return s < 60 ? "\(s)s ago" : "\(s / 60)m ago"
    }

    private static func budgetText() -> String {
        guard let s = freshSnapshot() else {
            return "Budget data unavailable — open Throttle (or it hasn't refreshed recently). I can't give a verified headroom number right now."
        }
        let h5 = max(0, 100 - s.session5hPercent), hw = max(0, 100 - s.weeklyAllPercent)
        return String(format: "5-hour cap: %.0f%% used, %.0f%% headroom left. 7-day cap: %.0f%% used, %.0f%% headroom left. (as of %@)",
                      s.session5hPercent, h5, s.weeklyAllPercent, hw, ago(s.computedAt))
    }

    private static func costText() -> String {
        guard let s = freshSnapshot() else {
            return "Cost data unavailable — open Throttle (or it hasn't refreshed recently)."
        }
        return String(format: "Last 7 days: %d weighted tokens, ≈€%.2f at developer-API rates (reference, not your actual subscription bill). Throttle's optimizations saved ≈%d tokens this week. (as of %@)",
                      s.weeklyTokens, s.weeklyCostEUR, s.savedTokensThisWeek, ago(s.computedAt))
    }

    private static func deadSkillsSchema() -> [String: Any] {
        [
            "name": "get_dead_skills",
            "description": "List the MCP servers and skills that are LOADED into every Claude Code session (costing schema tokens in the context window) but went UNUSED over the last 30 days. Purely informative context about your own tool-loadout weight — it does not tell you to change anything; the user decides what to prune.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ]
    }

    private static func deadSkillsText() -> String {
        let report = DeadSkillService.audit(loadout: ClaudeSetupService.load(), windowDays: 30)
        let dead = report.rows.filter(\.isDead)
        guard !dead.isEmpty else {
            return "No dead tools — every loaded MCP server / skill was used in the last 30 days (\(report.rows.count) loaded)."
        }
        let list = dead.map { "• \($0.name) — \($0.kind.rawValue)" }.joined(separator: "\n")
        return "Loaded but UNUSED in 30 days (paying schema tokens for nothing):\n\(list)\n\n\(dead.count) of \(report.rows.count) loaded tools are dead weight."
    }

    private static func mcpHealthSchema() -> [String: Any] {
        [
            "name": "get_mcp_health_status",
            "description": "Health of the user's OTHER MCP servers as last probed by Throttle: which are ok / slow / down / unreachable, their latency and tool count. Call this if one of your tools is failing or hanging, to know whether a server is a zombie. Informative only; reports how long ago it was probed.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ]
    }

    private static func mcpHealthText() -> String {
        guard let snap = ThrottleMCPHealthStore.read(), !snap.servers.isEmpty else {
            return "No MCP health data yet — open Throttle's cockpit so it probes your servers, then ask again."
        }
        let age = Int(max(0, Date().timeIntervalSince(snap.probedAt)))
        let ageStr = age < 60 ? "\(age)s ago" : (age < 3600 ? "\(age / 60)m ago" : "\(age / 3600)h ago")
        let lines = snap.servers.map { r -> String in
            var bits = [r.status]
            if let ms = r.latencyMs { bits.append("\(ms)ms") }
            if let t = r.toolCount { bits.append("\(t) tools") }
            return "• \(r.name): \(bits.joined(separator: " · "))"
        }.joined(separator: "\n")
        return "MCP servers (probed \(ageStr)):\n\(lines)"
    }

    private static func expandPointerSchema() -> [String: Any] {
        [
            "name": "throttle_expand_pointer",
            "description": "Rehydrate a payload that Throttle trimmed from a transcript to save tokens. When you see a marker like '[… trimmed by Throttle … throttle_expand_pointer(hash: \"…\")]' or '[image removed by Throttle …]', call this with that hash to get back the FULL original content (the complete tool output, or the base64 image data). Local content-addressed lookup; returns the exact bytes that were removed, or a not-found note if they have expired.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "hash": ["type": "string", "description": "The 64-char SHA-256 hash from the Throttle pointer."],
                ],
                "required": ["hash"],
            ],
        ]
    }

    private static func expandPointerText(_ hash: String) -> String {
        guard let data = ContentStore.get(hash) else {
            return "No stored payload for that hash — it may have expired (Throttle keeps trimmed originals ~30 days) or the hash is malformed. Resume the Throttle backup of that session to recover it."
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        return "[binary payload, \(data.count) bytes, base64-encoded below]\n" + data.base64EncodedString()
    }

    private static func recallSchema() -> [String: Any] {
        [
            "name": "throttle_recall",
            "description": "Recall durable knowledge Throttle has stored locally about a topic: long-term facts (DeltaMem — a general fact composed with any project-specific variations for the given scope) and validated research bundles (OKF). Use this when you need established prior knowledge rather than searching raw transcripts. Local; returns a not-found note if nothing is recorded.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "topic": ["type": "string", "description": "Subject to recall, e.g. 'Stripe API'."],
                    "scope": ["type": "string", "description": "Optional project/context to specialize the fact, e.g. 'Throttle'."],
                ],
                "required": ["topic"],
            ],
        ]
    }

    private static func recallText(topic: String, scope: String) -> String {
        var parts: [String] = []
        if let root = DeltaMemStore.findRoot(matching: topic),
           let resolved = DeltaMemStore.resolve(rootId: root.id, scope: scope) {
            parts.append("Known fact — \(root.title):\n\(resolved)")
        }
        let bundles = OKFStore.search(topic)
        if !bundles.isEmpty {
            let list = bundles.prefix(3).map { b in
                "• \(b.title) [\(b.confidence)] — \(String(b.body.prefix(240)))"
            }.joined(separator: "\n")
            parts.append("Knowledge bundles (OKF):\n\(list)")
        }
        return parts.isEmpty ? "Nothing recorded for “\(topic)”." : parts.joined(separator: "\n\n")
    }

    private static func semanticSearchSchema() -> [String: Any] {
        [
            "name": "throttle_semantic_search",
            "description": "Semantic (meaning-based) search over a repo's code + docs that Throttle has indexed locally with on-device embeddings — finds relevant chunks even when keywords don't match. Complements search_sessions (your past conversations) and plain grep (exact text). Defaults to the current project; returns a build hint if the repo hasn't been indexed yet.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "What you're looking for, in natural language."],
                    "repo": ["type": "string", "description": "Optional absolute repo path; defaults to the current working directory's repo."],
                    "k": ["type": "integer", "description": "Max results (default 6)."],
                ],
                "required": ["query"],
            ],
        ]
    }

    private static func semanticSearchText(query: String, repo: String?, k: Int) -> String {
        let root = repo.map { URL(fileURLWithPath: $0) }
            ?? SemanticCorpusStore.repoRoot(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        let index = SemanticCorpusStore.loadIndex(repo: root.standardizedFileURL.path)
        guard index.chunkCount > 0 else {
            return "No semantic index for \(root.lastPathComponent) yet. Build it with `Throttle --index-repo \(root.path)` (or from Throttle), then ask again."
        }
        let hits = index.searchHybrid(query, k: k)
        guard !hits.isEmpty else { return "No semantic matches for “\(query)” in \(root.lastPathComponent) (\(index.chunkCount) chunks indexed)." }
        return hits.map { h in
            let path = h.metadata["path"] ?? h.id
            let loc = h.metadata["line"].map { ":\($0)" } ?? ""
            let snippet = h.text.replacingOccurrences(of: "\n", with: " ").prefix(200)
            return "• \(path)\(loc) (\(String(format: "%.2f", h.score))) — \(snippet)"
        }.joined(separator: "\n")
    }

    private static func webRenderSchema() -> [String: Any] {
        [
            "name": "web_render",
            "description": "Fetch a web page the way a BROWSER sees it: Throttle renders the URL in a real (headless, on-device) WebKit engine, runs its JavaScript, and returns the readable text of the fully-rendered page. Unlike a plain HTTP fetch (which only sees the static server HTML), this captures content that appears only after the page's JS runs — single-page apps, client-rendered articles, lazy-loaded bodies. 100% local + private; nothing leaves the machine, and it uses an isolated cookie-less session. Requires the Throttle app to be running with Web research enabled (it returns a note if not).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "Public http(s) URL to render. Internal/loopback hosts are refused."],
                    "wait": ["type": "string", "description": "'networkIdle' (default — wait for the DOM to settle, best for SPAs), 'load' (fire as soon as the document loads), or 'selector' (wait for waitSelector)."],
                    "waitSelector": ["type": "string", "description": "CSS selector to wait for when wait='selector'."],
                    "maxChars": ["type": "integer", "description": "Cap on returned text length (default 12000)."],
                    "timeoutMs": ["type": "integer", "description": "Max render time in ms (default 15000, hard-capped at 30000)."],
                ],
                "required": ["url"],
            ],
        ]
    }

    private static func textResult(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]]]
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
