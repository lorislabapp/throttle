import Foundation

/// Detects a "Ralph Wiggum loop" — an agent burning tokens cycling the same action
/// while making no real progress — from the session TRANSCRIPT (not a network
/// proxy, keeping the no-data-path-proxy doctrine). Signature: the same tool_use
/// payload repeats while ZERO file-mutation tools fire over a recent window. The
/// cockpit surfaces a nudge quantifying the burn; pausing reuses the shipped
/// SIGSTOP/CONT. Advisory by default — never auto-kills.
struct LoopSignal: Sendable {
    let repeatedTool: String   // the action being cycled (e.g. "Bash: npm test")
    let repeats: Int           // how many times it repeated in the window
    let tokensBurned: Int      // ~output tokens spent in the window (for the nudge)
}

enum LoopDetectorService {

    /// Tools that change the codebase — their presence means real progress, so the
    /// loop heuristic only fires when NONE of these appear in the window.
    private static let mutationTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// Window of recent tool calls to inspect, and the repeat threshold.
    private static let window = 12
    private static let repeatThreshold = 4

    static func detect(cwd: String, sessionId: String) -> LoopSignal? {
        let encoded = encodedProject(cwd)
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/projects/\(encoded)/\(sessionId).jsonl")
        guard let tail = tailString(path: path, maxBytes: 256 * 1024) else { return nil }

        // Collect (signature, ~outputTokens) for tool_use blocks, in order.
        var sigs: [String] = []
        var tokensByIndex: [Int] = []
        for line in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("tool_use"),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let msg = obj["message"] as? [String: Any] else { continue }
            if let blocks = msg["content"] as? [[String: Any]] {
                let out = (msg["usage"] as? [String: Any])?["output_tokens"] as? Int ?? 0
                for b in blocks where (b["type"] as? String) == "tool_use" {
                    guard let name = b["name"] as? String else { continue }
                    sigs.append(signature(name: name, input: b["input"] as? [String: Any]))
                    tokensByIndex.append(out)
                }
            }
        }
        guard sigs.count >= window else { return nil }

        let recent = Array(sigs.suffix(window))
        let recentTokens = Array(tokensByIndex.suffix(window))
        // Any real file change in the window → genuine progress, not a loop.
        if recent.contains(where: { sig in mutationTools.contains(String(sig.prefix(while: { $0 != ":" }))) }) { return nil }

        // Most-repeated identical payload in the window.
        var counts: [String: Int] = [:]
        for s in recent { counts[s, default: 0] += 1 }
        guard let (sig, n) = counts.max(by: { $0.value < $1.value }), n >= repeatThreshold else { return nil }

        let burned = recentTokens.reduce(0, +)
        return LoopSignal(repeatedTool: prettySig(sig), repeats: n, tokensBurned: burned)
    }

    // MARK: - Helpers

    /// name + a short stable digest of the input (command for Bash, else the JSON).
    private static func signature(name: String, input: [String: Any]?) -> String {
        let detail: String
        if let cmd = input?["command"] as? String { detail = String(cmd.prefix(200)) }
        else if let input, let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) {
            detail = String(decoding: data.prefix(200), as: UTF8.self)
        } else { detail = "" }
        return "\(name):\(detail)"
    }

    private static func prettySig(_ sig: String) -> String {
        let parts = sig.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return sig }
        let name = parts[0], detail = parts[1].trimmingCharacters(in: .whitespaces)
        let short = detail.count > 48 ? String(detail.prefix(45)) + "…" : detail
        return short.isEmpty ? String(name) : "\(name): \(short)"
    }

    private static func encodedProject(_ cwd: String) -> String {
        String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    /// Read the last `maxBytes` of a file as text, dropping a possibly-partial
    /// first line. Cheap enough to run on the cockpit tick.
    private static func tailString(path: String, maxBytes: Int) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        if start > 0, let nl = text.firstIndex(of: "\n") { return String(text[text.index(after: nl)...]) }
        return text
    }
}
