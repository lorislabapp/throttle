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
            "failed": outcome.failed
        ]
        if let sessionId { rec["sid"] = sessionId }
        if let costEUR, costEUR.isFinite, costEUR >= 0 { rec["eur"] = costEUR }
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
        var eurPerGreen: Double?  // all observed attempt costs / green runs; estimate only
        var hasData: Bool { green + red > 0 }
        var passRate: Double { green + red == 0 ? 0 : Double(green) / Double(green + red) }
    }

    private struct Row {
        let timestamp: Int
        let order: Int
        let sid: String?
        let eur: Double?
        let green: Bool
        let framework: String?
    }

    /// Fold the log for one project over the last `days`. Cheap line scan.
    /// €/green includes failed attempts. Terminal observations and cumulative
    /// session costs are estimates, not unique accepted tasks or full billing.
    static func summary(project: String, days: Int = 14) -> Summary {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return Summary() }
        let cutoff = Int(Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970)
        return summarize(text: text, project: project, cutoff: cutoff)
    }

    /// Pure fold for deterministic verification. Pre-window samples anchor deltas.
    /// Missing costs or a counter reset make the estimate unavailable, not cheaper.
    static func summarize(text: String, project: String, cutoff: Int) -> Summary {
        var s = Summary()
        let rows = parseRows(text: text, project: project).sorted {
            $0.timestamp == $1.timestamp ? $0.order < $1.order : $0.timestamp < $1.timestamp
        }
        for row in rows where row.timestamp >= cutoff {
            if row.green { s.green += 1 } else { s.red += 1 }
            s.lastFramework = row.framework ?? s.lastFramework
        }
        if s.green > 0, let cost = totalObservedCost(rows: rows, cutoff: cutoff) {
            s.eurPerGreen = cost / Double(s.green)
        }
        return s
    }

    private static func parseRows(text: String, project: String) -> [Row] {
        var rows: [Row] = []
        for (order, line) in text.split(separator: "\n").enumerated() {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (o["project"] as? String) == project,
                  let timestamp = o["ts"] as? Int,
                  let failed = o["failed"] as? Int, failed >= 0,
                  let passed = o["passed"] as? Int, passed >= 0,
                  failed > 0 || passed > 0 else { continue }
            let green = failed == 0 && passed > 0
            rows.append(Row(timestamp: timestamp, order: order, sid: o["sid"] as? String,
                            eur: o["eur"] as? Double, green: green, framework: o["fw"] as? String))
        }
        return rows
    }

    private static func totalObservedCost(rows: [Row], cutoff: Int) -> Double? {
        var previous: [String: Double] = [:]
        var seenBeforeWindow = Set<String>()
        var totalCost = 0.0
        var completeCost = true
        for row in rows {
            let inWindow = row.timestamp >= cutoff
            if !inWindow, let sid = row.sid { seenBeforeWindow.insert(sid) }
            guard let sid = row.sid, !sid.isEmpty,
                  let cost = row.eur, cost.isFinite, cost >= 0 else {
                if inWindow { completeCost = false }
                continue
            }
            let prior = previous[sid]
            previous[sid] = cost
            guard inWindow else { continue }
            // A session first observed before the window but without a cost
            // anchor is unknown. A new session uses its cumulative cost estimate.
            if let prior, cost < prior { completeCost = false; continue }
            if prior == nil, seenBeforeWindow.contains(sid) { completeCost = false; continue }
            totalCost += cost - (prior ?? 0)
        }
        return completeCost && totalCost.isFinite ? totalCost : nil
    }
}
