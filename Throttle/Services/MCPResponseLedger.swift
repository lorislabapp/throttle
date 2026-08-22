import Foundation

/// Records how much each MCP tool call puts into context. **Measure only** —
/// nothing is rewritten, nothing is withheld from the model.
///
/// ## Why this exists
///
/// Throttle's hooks were all scoped to `Bash`, so it optimised the one tool it
/// was watching. Measured 2026-08-22 across 97 transcripts: thirty days of Bash
/// trimming kept 0.7 MB out of context, while MCP tool answers put **71 MB** in.
/// A hundred times the weight, no coverage at all. `claude-in-chrome` alone
/// accounted for 47.9 MB over 2260 calls; `xcode-mcp` answers in 57 KB per call.
///
/// ## Why it does not trim
///
/// The literature measures the saving and says plainly that the effect of
/// trimming tool results on task success is unquantified. Rewriting what the
/// model sees, on that basis, is a guess dressed as an optimisation — and this
/// codebase already learned today what an unverifiable claim costs.
///
/// So: measure live, per tool, and let the evidence decide later. The
/// retrospective transcript scan in `MCPAdvisorService` answers "what did this
/// server cost"; this answers "which call, right now, and how big", which is
/// what a trimming rule would need to be built on.
enum MCPResponseLedger {

    private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Throttle", isDirectory: true)
    }
    private static var fileURL: URL { appSupport.appendingPathComponent("mcp-responses.jsonl") }

    /// Below this a call is not worth a line in the ledger; the file would grow
    /// faster than the signal it carries.
    private static let floor = 512

    /// Record one MCP tool result. `tool` is the full `mcp__server__name`.
    static func record(tool: String, bytes: Int, textBytes: Int) {
        guard bytes >= floor, tool.hasPrefix("mcp__") else { return }
        let parts = tool.dropFirst(5).components(separatedBy: "__")
        let server = parts.first ?? ""
        guard !server.isEmpty else { return }

        var rec: [String: Any] = [
            "ts": Int(Date().timeIntervalSince1970),
            "server": server,
            "tool": tool,
            // Both numbers on purpose: `bytes` is the whole payload, `textBytes`
            // is what the model actually reads. The gap between them is JSON
            // punctuation, and a trimming rule that confuses the two would
            // report savings it never made.
            "bytes": bytes,
            "text_bytes": textBytes
        ]
        if parts.count > 1 { rec["name"] = parts.dropFirst().joined(separator: "__") }

        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        guard let line = try? JSONSerialization.data(withJSONObject: rec) else { return }
        let url = fileURL
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line); h.write(Data([0x0a])); try? h.close()
        } else {
            guard let text = String(data: line, encoding: .utf8) else { return }
            try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Size of a tool result as the model reads it: the text, not the envelope.
    static func textBytes(of response: Any?) -> Int {
        if let s = response as? String { return s.utf8.count }
        if let blocks = response as? [[String: Any]] {
            return blocks.reduce(0) { $0 + (($1["text"] as? String)?.utf8.count ?? 0) }
        }
        if let dict = response as? [String: Any] {
            if let content = dict["content"] { return textBytes(of: content) }
            return (try? JSONSerialization.data(withJSONObject: dict))?.count ?? 0
        }
        return 0
    }
}
