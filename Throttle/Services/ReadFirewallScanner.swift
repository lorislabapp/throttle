import Foundation

/// Read-Firewall detector — **measure-only**. Scans a project's recent transcripts
/// for the brute-force read signature (many whole-file `Read`s packed into a single
/// turn, or the same file read over and over) and surfaces it so you can scope your
/// reads or add local semantic retrieval yourself.
///
/// Per `docs/design-read-firewall.md`: Throttle does the safe half — detect +
/// attribute — and deliberately does NOT silently rewire a project's `.mcp.json`
/// (semantic recall is lossy; changing what the model sees without consent is the
/// golden-rule-adjacent risk). The nudge is informational; the fix stays the user's.
enum ReadFirewallScanner {
    struct Summary: Sendable, Equatable {
        var heavyTurns = 0        // assistant turns with ≥ heavyThreshold Reads in one turn
        var totalReads = 0        // total Read tool_use calls in the window
        var topFile: String?      // most-re-read file (basename), best-effort
        var topFileCount = 0
        var since: Date?
        var hasData: Bool { heavyTurns > 0 }
    }

    static let heavyThreshold = 3         // ≥3 Reads in one assistant turn = brute-force
    private static let windowDays = 14.0
    private static let reReadFloor = 4    // only call out a file re-read ≥4× as notable

    /// Off-main, best-effort, never throws. `encodedName` is the `~/.claude/projects`
    /// subdir (== `ProjectInfo.encodedName`).
    static func scan(encodedName: String) -> Summary {
        var s = Summary()
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(encodedName)", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return s }

        let cutoff = Date().addingTimeInterval(-windowDays * 86_400)
        let pathRE = try? NSRegularExpression(pattern: "\"file_path\"\\s*:\\s*\"([^\"]+)\"")
        var fileCounts: [String: Int] = [:]
        var earliest: Date?

        for f in files where f.pathExtension == "jsonl" {
            let mt = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard mt >= cutoff else { continue }
            guard let data = try? Data(contentsOf: f, options: .mappedIfSafe) else { continue }
            earliest = min(earliest ?? mt, mt)
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                // Cheap prefilter: only assistant lines that actually name a Read.
                guard line.contains("\"name\":\"Read\"") else { continue }
                let reads = line.components(separatedBy: "\"name\":\"Read\"").count - 1
                guard reads > 0 else { continue }
                s.totalReads += reads
                if reads >= heavyThreshold { s.heavyTurns += 1 }
                // Best-effort re-read attribution: count file_path basenames on Read lines.
                if let re = pathRE {
                    let str = String(line)
                    for m in re.matches(in: str, range: NSRange(str.startIndex..., in: str)) {
                        guard let r = Range(m.range(at: 1), in: str) else { continue }
                        let base = (String(str[r]) as NSString).lastPathComponent
                        fileCounts[base, default: 0] += 1
                    }
                }
            }
        }
        if let top = fileCounts.max(by: { $0.value < $1.value }), top.value >= reReadFloor {
            s.topFile = top.key; s.topFileCount = top.value
        }
        s.since = earliest
        return s
    }
}
