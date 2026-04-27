import Foundation

struct AnthropicWarning: Equatable, Sendable {
    enum Window: String, Sendable { case session, weekly }
    let percent: Int
    let window: Window
}

enum WarningDetector {
    /// Best-effort detection of Claude Code's percentage warnings in a JSONL line.
    /// The exact format is not officially documented; this matches several plausible phrasings.
    /// Returns nil for non-warning lines and malformed input.
    static func detect(inLine line: String) throws -> AnthropicWarning? {
        guard let data = line.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard (raw["type"] as? String) == "system" else { return nil }
        guard let message = raw["message"] as? [String: Any] else { return nil }
        guard let content = message["content"] as? String else { return nil }

        let lower = content.lowercased()
        guard let percent = extractPercent(from: lower) else { return nil }

        let window: AnthropicWarning.Window
        if lower.contains("week") {
            window = .weekly
        } else if lower.contains("session") || lower.contains("5-hour") || lower.contains("5 hour") {
            window = .session
        } else {
            return nil
        }
        return AnthropicWarning(percent: percent, window: window)
    }

    private static func extractPercent(from text: String) -> Int? {
        let pattern = #"(\d{1,3})\s*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        guard let r = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[r])
    }
}
