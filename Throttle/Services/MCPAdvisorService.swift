import Foundation

/// On-device MCP advisor — the "local AI that recommends" MCP management, in the
/// doctrine sense: pure heuristic over local signals, zero cloud, zero LLM. For
/// each configured MCP server it combines
///   • **usage** — how many `mcp__<name>__…` tool calls appear in the last 30 days
///     of Claude Code transcripts (the real "is this server actually used" signal),
///   • **cost** — best-effort resident memory of matching running child processes,
///   • **transport** — stdio-local (spawns a process on the Mac) vs remote HTTP,
/// into a verdict: keep / disable / offload / review.
///
/// Memory-disciplined (this is the 16 GB-relief feature — it must not itself be a
/// hog): transcripts are scanned via memory-mapped `Data` and a raw byte search,
/// only files modified in the last 30 days, skipped entirely under memory pressure.
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
        let estRSSBytes: UInt64      // 0 when no running process matched
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

        let usage = usageCounts(names: servers.map(\.name))
        let rss = estimatedRSS(for: servers)

        return servers.map { s in
            let remote = s.transport.hasPrefix("HTTP")
            let calls = usage[s.name] ?? 0
            let bytes = rss[s.name] ?? 0
            let (verdict, reason) = decide(name: s.name, remote: remote,
                                           disabled: s.disabled, calls: calls, rss: bytes)
            return Recommendation(name: s.name, scopeKey: s.scope.key, transportRemote: remote,
                                  calls30d: calls, estRSSBytes: bytes, verdict: verdict, reason: reason)
        }
        .sorted { rank($0.verdict) != rank($1.verdict) ? rank($0.verdict) < rank($1.verdict) : $0.name < $1.name }
    }

    private static func rank(_ v: Verdict) -> Int {
        switch v { case .disable: return 0; case .offload: return 1; case .review: return 2; case .keep: return 3 }
    }

    // MARK: - Heuristic

    private static func decide(name: String, remote: Bool, disabled: Bool,
                               calls: Int, rss: UInt64) -> (Verdict, String) {
        if disabled {
            return calls == 0
                ? (.keep, "Disabled and unused — leave it off.")
                : (.review, "Disabled but used \(calls)× in 30d — re-enable if you still need it.")
        }
        if remote {
            return (.keep, "Already remote (HTTP) — no local process on the Mac.")
        }
        // stdio-local from here → it spawns a child process on the Mac.
        let ram = rss > 0 ? " (~\(mb(rss)) resident)" : ""
        if calls == 0 {
            return (.disable, "No tool calls in 30 days\(ram) — a local process spawned for nothing, plus its tool list in every session's context. Disable it.")
        }
        return (.offload, "Used \(calls)× in 30d and runs locally\(ram) — if it doesn't read local files/repos, host it on your server over HTTP so `claude` connects by URL and spawns zero process on the Mac (a preflight confirms before moving).")
    }

    /// LLM-ready seam. Today: the heuristic reason. Later: a local model could
    /// take the raw signals (name/calls/rss/transport/verdict) and phrase them.
    static func explain(_ r: Recommendation) -> String { r.reason }

    private static func mb(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    // MARK: - Usage signal (last-30d transcript scan, memory-mapped)

    /// Count `mcp__<name>__` occurrences across recent transcripts. One byte scan
    /// per file over a memory-mapped buffer (no heap blow-up on huge transcripts),
    /// only files modified within the window.
    private static func usageCounts(names: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        let nameSet = Set(names)
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        let cutoff = Date().addingTimeInterval(-window)
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: projects,
                                         includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return counts }
        let needle: [UInt8] = Array("mcp__".utf8)
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let m = vals.contentModificationDate, m >= cutoff else { continue }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            scan(data, needle: needle) { serverName in
                if nameSet.contains(serverName) { counts[serverName, default: 0] += 1 }
            }
        }
        return counts
    }

    /// Find each `mcp__<server>__` and hand the captured `<server>` to `hit`.
    private static func scan(_ data: Data, needle: [UInt8], hit: (String) -> Void) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = raw.count, k = needle.count
            var i = 0
            while i + k < n {
                var match = true
                for j in 0..<k where base[i + j] != needle[j] { match = false; break }
                if match {
                    // read name until the closing "__"
                    var j = i + k
                    var bytes = [UInt8]()
                    while j + 1 < n, !(base[j] == 0x5f && base[j + 1] == 0x5f), bytes.count < 64 {
                        let c = base[j]
                        // server names are [A-Za-z0-9_-]; stop at anything else
                        let ok = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 45 || c == 95
                        if !ok { break }
                        bytes.append(c); j += 1
                    }
                    if !bytes.isEmpty, let s = String(bytes: bytes, encoding: .utf8) { hit(s) }
                    i = j
                } else {
                    i += 1
                }
            }
        }
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
