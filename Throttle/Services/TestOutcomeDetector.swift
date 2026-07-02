import Foundation

/// Detects a test-runner SUMMARY line in a session's terminal output and extracts
/// pass/fail counts. Pure + best-effort — fires only on an unambiguous end-of-run
/// summary, never on incidental "passed" prose. Feeds the eval-ROI readout
/// ("cost per green run"); measure-only, changes nothing. Supports the runners a
/// Claude Code user actually hits: pytest, cargo, go, jest/vitest, swift test.
enum TestOutcomeDetector {
    struct Outcome: Sendable, Equatable {
        let framework: String
        let passed: Int
        let failed: Int
        var green: Bool { failed == 0 && passed > 0 }
    }

    /// Scan the tail (summaries are at the end of a run). Returns the FIRST framework
    /// whose summary matches; nil if none.
    static func detect(in text: String) -> Outcome? {
        let tail = String(text.suffix(2000))

        // pytest: "===== 12 passed, 2 failed in 3.41s =====" | "12 passed in 1.2s"
        if let c = caps(tail, #"(\d+) passed(?:, (\d+) failed)?[^\n]* in \d"#) {
            return Outcome(framework: "pytest", passed: c[0] ?? 0, failed: c[1] ?? 0)
        }
        // cargo: "test result: ok. 12 passed; 0 failed;" | "test result: FAILED. 10 passed; 2 failed;"
        if let c = caps(tail, #"test result: \w+\. (\d+) passed; (\d+) failed"#) {
            return Outcome(framework: "cargo", passed: c[0] ?? 0, failed: c[1] ?? 0)
        }
        // jest / vitest: "Tests:       2 failed, 10 passed, 12 total" (failed FIRST) or "Tests: 10 passed, 12 total"
        if let c = caps(tail, #"Tests:\s+(?:(\d+) failed, )?(\d+) passed"#) {
            return Outcome(framework: "jest", passed: c[1] ?? 0, failed: c[0] ?? 0)
        }
        // swift test: "Executed 12 tests, with 2 failures (0 unexpected)"
        if let c = caps(tail, #"Executed (\d+) tests?, with (\d+) failure"#) {
            let total = c[0] ?? 0, fail = c[1] ?? 0
            return Outcome(framework: "swift", passed: max(0, total - fail), failed: fail)
        }
        // go: a run's final "ok  <pkg>  0.5s" (pass) or "FAIL  <pkg>" (fail). No counts,
        // so treat a package result as one unit. Require the line-anchored token to
        // avoid matching prose. Checked last (weakest signal).
        if caps(tail, #"(?m)^FAIL\s+\S"#) != nil { return Outcome(framework: "go", passed: 0, failed: 1) }
        if caps(tail, #"(?m)^ok\s+\S+\s+\d"#) != nil { return Outcome(framework: "go", passed: 1, failed: 0) }
        return nil
    }

    /// Return the integer captures of the first match (nil per absent/optional group).
    private static func caps(_ text: String, _ pattern: String) -> [Int?]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        var out: [Int?] = []
        for i in 1..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: text) { out.append(Int(text[r])) }
            else { out.append(nil) }
        }
        return out
    }
}
