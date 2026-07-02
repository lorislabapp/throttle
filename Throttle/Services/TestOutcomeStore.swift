import Foundation

/// Append-only log of detected test-run outcomes per project, feeding the eval-ROI
/// readout ("cost per green run"). Measure-only telemetry — no secrets (just counts
/// + framework + project label), local file, never leaves the Mac.
enum TestOutcomeStore {
    private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Throttle", isDirectory: true)
    }
    private static var fileURL: URL { appSupport.appendingPathComponent("test-outcomes.jsonl") }

    /// One record. `project` is the encoded transcript dir name (stable per repo).
    /// `sessionId` + `costEUR` (the session's cumulative cost at this moment) let the
    /// summary attribute per-run cost via consecutive deltas → "€ per green run".
    static func record(project: String, sessionId: String?, costEUR: Double?,
                       outcome: TestOutcomeDetector.Outcome) {
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        var rec: [String: Any] = [
            "ts": Int(Date().timeIntervalSince1970),
            "project": project,
            "fw": outcome.framework,
            "passed": outcome.passed,
            "failed": outcome.failed,
        ]
        if let sessionId { rec["sid"] = sessionId }
        if let costEUR { rec["eur"] = costEUR }
        guard let line = try? JSONSerialization.data(withJSONObject: rec) else { return }
        let url = fileURL
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line); h.write(Data([0x0a])); try? h.close()
        } else {
            try? (String(data: line, encoding: .utf8)! + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    struct Summary: Sendable, Equatable {
        var green = 0            // runs with 0 failures
        var red = 0             // runs with ≥1 failure
        var lastFramework: String?
        var eurPerGreen: Double?  // mean per-run cost attributed to green runs, if derivable
        var hasData: Bool { green + red > 0 }
        var passRate: Double { green + red == 0 ? 0 : Double(green) / Double(green + red) }
    }

    private struct Row { let ts: Int; let sid: String?; let eur: Double?; let green: Bool }

    /// Fold the log for one project over the last `days`. Cheap line scan.
    /// €/green: within each session (sorted by ts), the cumulative session cost's
    /// consecutive delta is the cost incurred to reach that run; the mean of those
    /// deltas over green runs is the "cost per green run".
    static func summary(project: String, days: Int = 14) -> Summary {
        var s = Summary()
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return s }
        let cutoff = Int(Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970)
        var rows: [Row] = []
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (o["project"] as? String) == project,
                  let ts = o["ts"] as? Int, ts >= cutoff else { continue }
            let failed = (o["failed"] as? Int) ?? 0
            let passed = (o["passed"] as? Int) ?? 0
            let green = failed == 0 && passed > 0
            if green { s.green += 1 } else { s.red += 1 }
            s.lastFramework = (o["fw"] as? String) ?? s.lastFramework
            rows.append(Row(ts: ts, sid: o["sid"] as? String, eur: o["eur"] as? Double, green: green))
        }
        // Per-session consecutive cost deltas → per-run cost; average over green runs.
        var greenCost = 0.0, greenCounted = 0
        for (_, group) in Dictionary(grouping: rows.filter { $0.sid != nil }, by: { $0.sid! }) {
            let sorted = group.sorted { $0.ts < $1.ts }
            var prev = 0.0
            for r in sorted {
                guard let e = r.eur else { continue }   // no cost yet → skip this run's delta
                let delta = max(0, e - prev); prev = e
                if r.green { greenCost += delta; greenCounted += 1 }
            }
        }
        if greenCounted > 0 { s.eurPerGreen = greenCost / Double(greenCounted) }
        return s
    }
}
