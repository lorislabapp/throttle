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
    static func record(project: String, outcome: TestOutcomeDetector.Outcome) {
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let rec: [String: Any] = [
            "ts": Int(Date().timeIntervalSince1970),
            "project": project,
            "fw": outcome.framework,
            "passed": outcome.passed,
            "failed": outcome.failed,
        ]
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
        var hasData: Bool { green + red > 0 }
        var passRate: Double { green + red == 0 ? 0 : Double(green) / Double(green + red) }
    }

    /// Fold the log for one project over the last `days`. Cheap line scan.
    static func summary(project: String, days: Int = 14) -> Summary {
        var s = Summary()
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return s }
        let cutoff = Int(Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970)
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (o["project"] as? String) == project,
                  (o["ts"] as? Int) ?? 0 >= cutoff else { continue }
            let failed = (o["failed"] as? Int) ?? 0
            let passed = (o["passed"] as? Int) ?? 0
            if failed == 0 && passed > 0 { s.green += 1 } else { s.red += 1 }
            s.lastFramework = (o["fw"] as? String) ?? s.lastFramework
        }
        return s
    }
}
