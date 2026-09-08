import Foundation

/// Best-effort terminal telemetry, never task acceptance. A tail can contain
/// several suite summaries; a success must not hide an observed failure.
enum TestOutcomeDetector {
    struct Outcome: Sendable, Equatable {
        let framework: String
        let passed: Int
        let failed: Int
        var green: Bool { failed == 0 && passed > 0 }
    }

    static func detect(in text: String) -> Outcome? {
        let plain = String(text.suffix(8_000)).replacingOccurrences(
            of: "\u{001B}" + #"\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression
        )
        let lines = plain.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let outcomes = lines.compactMap(parse)
        if let failure = outcomes.last(where: { $0.failed > 0 }) { return failure }
        // A contradictory/truncated transcript cannot support a green signal.
        if lines.contains(where: {
            $0.contains("test result: FAILED") || $0 == "** TEST FAILED **"
                || $0 == "** TEST EXECUTE FAILED **"
                || matches($0, #"\b[1-9]\d* (?:failed|failures?|errors?)\b"#)
                || matches($0, #"^[✘✖].*(?:failed|issue)"#)
                || matches($0, #"^ℹ fail [1-9]\d*\b"#)
        }) { return nil }
        return outcomes.last(where: { $0.green })
    }

    private static func parse(_ line: String) -> Outcome? {
        if let result = pytest(line) { return result }
        if let values = captures(line, #"^test result: (?:ok|FAILED)\. (\d+) passed; (\d+) failed;"#),
           let passed = Int(values[0]), let failed = Int(values[1]) {
            guard !line.contains("FAILED") || failed > 0 else { return nil }
            return Outcome(framework: "cargo", passed: passed, failed: failed)
        }
        let swiftSummary = #"^Executed (\d+) tests?, with "#
            + #"(?:(\d+) tests? skipped and )?(\d+) failures?(?: |$)"#
        if let values = captures(line, swiftSummary),
           let total = Int(values[0]), let failed = Int(values[2]) {
            let skipped = Int(values[1]) ?? 0
            guard failed <= total, skipped <= total - failed else { return nil }
            return Outcome(framework: "swift", passed: total - failed - skipped, failed: failed)
        }
        if line.hasPrefix("Tests:"),
           matches(line, #"^Tests:\s+(?:\d+ (?:failed|passed|skipped|todo|total)(?:,\s*|$))+$"#) {
            return counted(line, framework: "jest")
        }
        if matches(line, #"^FAIL(?:\s+\S+)?(?:\s+\d+(?:\.\d+)?s)?$"#) {
            return Outcome(framework: "go", passed: 0, failed: 1)
        }
        if matches(line, #"^ok\s+\S+\s+(?:\d+(?:\.\d+)?s|\(cached\))$"#) {
            return Outcome(framework: "go", passed: 1, failed: 0)
        }
        return nil
    }

    private static func pytest(_ line: String) -> Outcome? {
        let body = line.trimmingCharacters(in: CharacterSet(charactersIn: "= "))
        let summary = #"^(?:\d+ (?:passed|failed|errors?|skipped|deselected|xfailed|xpassed)(?:,\s*| ))+"#
            + #"in \d+(?:\.\d+)?s(?: \([^)]*\))?$"#
        guard matches(body, summary) else { return nil }
        return counted(body, framework: "pytest")
    }

    private static func counted(_ line: String, framework: String) -> Outcome? {
        // An overflowing counter must not silently become zero failures.
        guard line.split(whereSeparator: { !$0.isNumber }).allSatisfy({ Int($0) != nil }) else { return nil }
        let passed = captures(line, #"(?:^|\s)(\d+) passed\b"#).flatMap { Int($0[0]) } ?? 0
        let failed = captures(line, #"(?:^|\s)(\d+) failed\b"#).flatMap { Int($0[0]) } ?? 0
        let errors = captures(line, #"(?:^|\s)(\d+) errors?\b"#).flatMap { Int($0[0]) } ?? 0
        let sum = failed.addingReportingOverflow(errors)
        guard !sum.overflow, passed > 0 || sum.partialValue > 0 else { return nil }
        return Outcome(framework: framework, passed: passed, failed: sum.partialValue)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func captures(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
