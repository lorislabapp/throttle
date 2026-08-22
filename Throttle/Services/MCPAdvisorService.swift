import Foundation

/// On-device MCP advisor — the "local AI that recommends" MCP management, in the
/// doctrine sense: pure heuristic over local signals, zero cloud, zero LLM. For
/// each configured MCP server it combines
///   • **usage** — how many `mcp__<name>__…` tool calls appear in the last 30 days
///     of Claude Code transcripts (the real "is this server actually used" signal),
///   • **cost** — best-effort resident memory of matching running child processes,
///   • **responses** — the bytes of tool *results* the server injected into
///     context over the window, read straight from the transcripts. This dwarfs
///     everything else and is the reason a "cheap" server can be expensive,
///   • **context** — the last measured byte weight of the server's `tools/list`
///     JSON (`MCPSchemaCache`), which is paid on *every* turn of every session the
///     server is enabled in, whether or not a single tool gets called,
///   • **transport** — stdio-local (spawns a process on the Mac) vs remote HTTP,
/// into a verdict: keep / disable / offload / review.
///
/// Context weight is why a *remote* server is no longer an automatic `keep`: it
/// spawns nothing on the Mac, but an unused one still bills its tool list into the
/// prompt every turn. That cost is invisible in `ps` and was the gap this advisor
/// had — measured 2026-08-21, 419 tools / 18 027 bytes of tool names across all
/// servers before a character is typed.
///
/// Memory-disciplined (this is the 16 GB-relief feature — it must not itself be a
/// hog): transcripts are memory-mapped and walked line by line, JSON is parsed only
/// for the handful of lines that mention a tool, only files modified in the last 30
/// days are opened, and the whole pass is skipped under memory pressure.
///
/// LLM-ready seam: `explain(_:)` returns the heuristic reason today; a small local
/// model could later replace it to phrase the signals in natural language without
/// changing callers.
enum MCPAdvisorService {

    enum Verdict: String, Sendable { case keep, disable, offload, review }

    struct Recommendation: Identifiable, Sendable {
        let name: String
        let scopeKey: String
        let transportRemote: Bool
        let calls30d: Int
        /// Bytes of tool *results* this server put into context over the window.
        /// Measured, not estimated — and the number that actually matters: on this
        /// Mac on 2026-08-22 the tool NAMES of every server together came to 18 KB,
        /// while 30 days of responses came to 71 MB.
        let responseBytes: Int
        let estRSSBytes: UInt64      // 0 when no running process matched
        /// Last measured `tools/list` weight. `nil` = never probed — say "not
        /// measured", never guess.
        let context: MCPSchemaCache.Entry?
        let verdict: Verdict
        let reason: String
        var id: String { scopeKey + "/" + name }
    }

    private static let window: TimeInterval = 30 * 24 * 3600

    /// Analyze every configured server. Heavy work (transcript scan + ps sweep) is
    /// synchronous here — call it off-main. Returns [] under memory pressure.
    static func analyze(memoryQuiet: Bool) -> [Recommendation] {
        guard !memoryQuiet else { return [] }
        let servers = MCPConfigService.list()
        guard !servers.isEmpty else { return [] }

        let (usage, responses) = usageAndResponseBytes(names: servers.map(\.name))
        let rss = estimatedRSS(for: servers)
        let schema = MCPSchemaCache.load()

        return servers.map { s in
            let remote = s.transport.hasPrefix("HTTP")
            let calls = usage[s.name] ?? 0
            let bytes = rss[s.name] ?? 0
            let ctx = schema[s.name]
            let resp = responses[s.name] ?? 0
            let (verdict, reason) = decide(name: s.name, remote: remote, disabled: s.disabled,
                                           calls: calls, rss: bytes, context: ctx, responseBytes: resp)
            return Recommendation(name: s.name, scopeKey: s.scope.key, transportRemote: remote,
                                  calls30d: calls, responseBytes: resp, estRSSBytes: bytes,
                                  context: ctx, verdict: verdict, reason: reason)
        }
        .sorted { rank($0.verdict) != rank($1.verdict) ? rank($0.verdict) < rank($1.verdict) : $0.name < $1.name }
    }

    private static func rank(_ v: Verdict) -> Int {
        switch v { case .disable: return 0; case .offload: return 1; case .review: return 2; case .keep: return 3 }
    }

    // MARK: - Heuristic

    private static func decide(name: String, remote: Bool, disabled: Bool, calls: Int,
                               rss: UInt64, context: MCPSchemaCache.Entry?,
                               responseBytes: Int) -> (Verdict, String) {
        if disabled {
            // A disabled server injects nothing, so context weight is moot here.
            return calls == 0
                ? (.keep, "Disabled and unused — leave it off.")
                : (.review, "Disabled but used \(calls)× in 30d — re-enable if you still need it.")
        }

        let ctx = contextPhrase(context, remote: remote)
        let answers = responsePhrase(responseBytes, calls: calls)

        if remote {
            // No longer an automatic keep. A remote server spawns nothing on the
            // Mac, but its tool list is still billed into every turn's prompt.
            if calls == 0 {
                return (.disable, "No tool calls in 30 days. It spawns no process on the Mac, but \(ctx) whether you use it or not. Disable it for projects that don't need it.")
            }
            return (.keep, "Remote (HTTP), used \(calls)× in 30d — no local process.\(answers) Note \(ctx).")
        }

        // stdio-local from here → it spawns a child process on the Mac.
        let ram = rss > 0 ? " (~\(mb(rss)) resident)" : ""
        if calls == 0 {
            return (.disable, "No tool calls in 30 days\(ram) — a local process spawned for nothing, and \(ctx). Disable it.")
        }
        return (.offload, "Used \(calls)× in 30d and runs locally\(ram).\(answers) If it doesn't read local files/repos, host it on your server over HTTP so `claude` connects by URL and spawns zero process on the Mac (a preflight confirms before moving). Either way \(ctx).")
    }

    /// What the server's answers cost. Silent when nothing was measured — a
    /// server can be used heavily and answer in a few bytes, and saying "0 MB"
    /// where we simply have no data would read as a finding.
    private static func responsePhrase(_ bytes: Int, calls: Int) -> String {
        guard bytes > 0, calls > 0 else { return "" }
        let per = bytes / calls
        let tokens = TokenEstimate.fromBytes(bytes, kind: .mixed)
        return " Its answers put \(mb(UInt64(bytes))) into context over 30 days"
            + " (~\(tokens) tokens, \(mb(UInt64(per))) per call)."
    }

    /// Phrase the context cost without ever inventing one. Stdio servers can be
    /// probed on demand; remote tool lists aren't probed yet, so say that plainly
    /// instead of implying the user forgot to measure.
    private static func contextPhrase(_ e: MCPSchemaCache.Entry?, remote: Bool) -> String {
        guard let e else {
            return "its tool list is injected into every turn's context (weight not measured — run the MCP probe to put a number on it)"
        }
        let age = Int(e.age / 86_400)
        let when = age <= 0 ? "measured today" : "measured \(age)d ago"
        // Two numbers, never one: Claude Code defers tool schemas and injects names
        // only, so the floor is what you actually pay today — but a client that
        // sends full schemas pays the ceiling, and the spread reaches 13×.
        if let floor = e.nameTokensEst {
            return "its \(e.tools) tools cost ~\(floor) tokens of context on every turn as names alone, up to ~\(e.tokensEst) if full schemas are sent (\(when))"
        }
        return "its \(e.tools) tools weigh ~\(e.tokensEst) tokens of context when full schemas are sent (\(when))"
    }

    /// LLM-ready seam. Today: the heuristic reason. Later: a local model could
    /// take the raw signals (name/calls/rss/transport/verdict) and phrase them.
    static func explain(_ r: Recommendation) -> String { r.reason }

    private static func mb(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    // MARK: - Usage signal (last-30d transcript scan, memory-mapped)

    /// Walk the last 30 days of transcripts once and return both signals: how many
    /// times each server was called, and how many bytes its answers put into
    /// context.
    ///
    /// Pairing matters. A `tool_use` block carries the server in its name and an
    /// `id`; the answer arrives later as a `tool_result` carrying only
    /// `tool_use_id`. Without threading that id through, a result cannot be
    /// attributed to anything — which is why response weight went unmeasured until
    /// now while call counts were easy.
    ///
    /// Memory discipline (this is the 16 GB-relief feature — it must not itself be
    /// a hog): files are read as a stream of lines, never loaded whole, and JSON is
    /// parsed only for the few lines that mention a tool. Everything else is
    /// rejected by a substring test before any allocation.
    private static func usageAndResponseBytes(names: [String]) -> ([String: Int], [String: Int]) {
        var counts: [String: Int] = [:]
        var bytes: [String: Int] = [:]
        var serverForUseID: [String: String] = [:]
        let nameSet = Set(names)

        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        let cutoff = Date().addingTimeInterval(-window)
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: projects,
                                         includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return (counts, bytes) }

        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let m = vals.contentModificationDate, m >= cutoff else { continue }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let text = String(data: data, encoding: .utf8) else { continue }

            text.enumerateLines { line, _ in
                let interesting = line.contains("mcp__") || line.contains("tool_use_id")
                guard interesting else { return }
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let message = obj["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { return }
                for block in content {
                    switch block["type"] as? String {
                    case "tool_use":
                        guard let name = block["name"] as? String, name.hasPrefix("mcp__"),
                              let id = block["id"] as? String else { continue }
                        // mcp__<server>__<tool> — take the segment between the pairs.
                        let server = name.dropFirst(5).components(separatedBy: "__").first ?? ""
                        guard nameSet.contains(server) else { continue }
                        counts[server, default: 0] += 1
                        serverForUseID[id] = server
                    case "tool_result":
                        guard let id = block["tool_use_id"] as? String,
                              let server = serverForUseID[id] else { continue }
                        bytes[server, default: 0] += resultBytes(block["content"])
                    default:
                        continue
                    }
                }
            }
        }
        return (counts, bytes)
    }

    /// Size of a tool result as it lands in context. The payload is either a plain
    /// string or an array of content blocks; re-serializing the whole block would
    /// add JSON punctuation the model never sees, so only the text is counted.
    private static func resultBytes(_ content: Any?) -> Int {
        if let s = content as? String { return s.utf8.count }
        if let blocks = content as? [[String: Any]] {
            return blocks.reduce(0) { $0 + (($1["text"] as? String)?.utf8.count ?? 0) }
        }
        return 0
    }

    // MARK: - RSS signal (best-effort process match)

    /// Best-effort resident memory per stdio server: one `ps` sweep of
    /// pid/rss/command, matched against each server's most distinctive launch
    /// argument (the longest arg, usually a package name or script path). Fuzzy —
    /// reported as an estimate, omitted when nothing confidently matches.
    private static func estimatedRSS(for servers: [MCPConfigService.Entry]) -> [String: UInt64] {
        // distinctive token per stdio server
        var token: [String: String] = [:]
        for s in servers where !s.transport.hasPrefix("HTTP") {
            guard let obj = try? JSONSerialization.jsonObject(with: s.rawData) as? [String: Any] else { continue }
            let args = (obj["args"] as? [String]) ?? []
            // pick the longest arg that looks like a path/package (contains / @ or .)
            let candidate = args
                .filter { $0.contains("/") || $0.contains("@") || $0.contains(".") }
                .max(by: { $0.count < $1.count })
                ?? args.max(by: { $0.count < $1.count })
            if let candidate, candidate.count >= 4 { token[s.name] = candidate }
        }
        guard !token.isEmpty else { return [:] }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "rss=,command="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return [:] }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let text = String(data: out, encoding: .utf8) else { return [:] }

        var rss: [String: UInt64] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            guard let sp = trimmed.firstIndex(of: " ") else { continue }
            guard let kb = UInt64(trimmed[trimmed.startIndex..<sp]) else { continue }
            let cmd = trimmed[trimmed.index(after: sp)...]
            for (name, tok) in token where cmd.contains(tok) {
                rss[name, default: 0] += kb * 1024
            }
        }
        return rss
    }
}
