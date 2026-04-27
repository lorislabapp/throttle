import Foundation

enum UsageExtractor {
    /// Returns nil if the line is not a usage-bearing assistant message.
    /// Throws only on programmer error; malformed JSON returns nil.
    static func extract(fromLine line: String) throws -> UsageEvent? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard (raw["type"] as? String) == "assistant" else { return nil }
        guard let sessionId = raw["sessionId"] as? String else { return nil }
        guard let message = raw["message"] as? [String: Any] else { return nil }
        guard let usage = message["usage"] as? [String: Any] else { return nil }

        let model = (message["model"] as? String) ?? "unknown"
        let timestamp = parseTimestamp(raw["timestamp"]) ?? Int64(Date().timeIntervalSince1970)

        return UsageEvent(
            id: nil,
            sessionId: sessionId,
            timestamp: timestamp,
            model: model,
            inputTokens: (usage["input_tokens"] as? Int) ?? 0,
            outputTokens: (usage["output_tokens"] as? Int) ?? 0,
            cacheCreate: (usage["cache_creation_input_tokens"] as? Int) ?? 0,
            cacheRead: (usage["cache_read_input_tokens"] as? Int) ?? 0,
            serviceTier: usage["service_tier"] as? String
        )
    }

    private static func parseTimestamp(_ value: Any?) -> Int64? {
        guard let str = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: str) { return Int64(date.timeIntervalSince1970) }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: str) { return Int64(date.timeIntervalSince1970) }
        return nil
    }
}
