import Foundation

/// Bounded, read-only adapter for Codex's observed local rollout format.
/// Unknown or changed shapes fail closed to `nil` instead of displaying a
/// plausible but fabricated metric.
enum CodexUsageService {
    private static let tailBytes: UInt64 = 512 * 1024

    nonisolated static func latestSnapshot(
        sessionsRoot: URL? = nil,
        now: Date = Date()
    ) -> CodexUsageSnapshot? {
        let root = sessionsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let urls = recentRolloutURLs(root: root, now: now)
        for url in urls {
            if let snapshot = snapshot(from: url) { return snapshot }
        }
        return nil
    }

    /// Codex stores rollouts below YYYY/MM/DD. Looking at the last three days
    /// bounds menu-bar refresh work even when years of sessions are retained.
    nonisolated static func recentRolloutURLs(root: URL, now: Date) -> [URL] {
        let fm = FileManager.default
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var urls: [URL] = []

        for offset in 0..<3 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayNumber = parts.day else { continue }
            let directory = root
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", dayNumber), isDirectory: true)
            let children = (try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            urls.append(contentsOf: children.filter { $0.pathExtension == "jsonl" })
        }

        // A custom/test store may place files directly at the supplied root.
        let direct = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        urls.append(contentsOf: direct.filter { $0.pathExtension == "jsonl" })

        return Array(Set(urls)).sorted { lhs, rhs in
            modificationDate(lhs) > modificationDate(rhs)
        }
    }

    nonisolated private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    nonisolated static func snapshot(from url: URL) -> CodexUsageSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > tailBytes ? end - tailBytes : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            if let snapshot = decodeLine(Data(line.utf8)) { return snapshot }
        }
        return nil
    }

    nonisolated static func decodeLine(_ data: Data) -> CodexUsageSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count" else { return nil }

        let info = payload["info"] as? [String: Any]
        let total = info?["total_token_usage"] as? [String: Any]
        let rateLimits = payload["rate_limits"] as? [String: Any]
        guard let observedAt = date(object["timestamp"]) else { return nil }
        let tokens = total.flatMap(decodeTokens)
        let primary = decodeWindow(rateLimits?["primary"], kind: .primary)
        let secondary = decodeWindow(rateLimits?["secondary"], kind: .secondary)

        // A token_count envelope with neither usage nor limits is not evidence.
        guard tokens != nil || primary != nil || secondary != nil else { return nil }
        return CodexUsageSnapshot(
            sessionID: string(payload["session_id"]) ?? string(object["session_id"]),
            tokens: tokens,
            contextWindow: integer(info?["model_context_window"]),
            primary: primary,
            secondary: secondary,
            planType: string(rateLimits?["plan_type"]),
            observedAt: observedAt
        )
    }

    nonisolated private static func decodeTokens(_ value: [String: Any]) -> CodexUsageSnapshot.Tokens? {
        guard let total = integer(value["total_tokens"]) else { return nil }
        return .init(
            input: integer(value["input_tokens"]) ?? 0,
            cachedInput: integer(value["cached_input_tokens"]) ?? 0,
            output: integer(value["output_tokens"]) ?? 0,
            reasoning: integer(value["reasoning_output_tokens"]) ?? 0,
            total: total
        )
    }

    nonisolated private static func decodeWindow(
        _ value: Any?,
        kind: CodexUsageSnapshot.RateWindow.Kind
    ) -> CodexUsageSnapshot.RateWindow? {
        guard let object = value as? [String: Any],
              let used = number(object["used_percent"]), used.isFinite else { return nil }
        return .init(
            kind: kind,
            usedPercent: min(100, max(0, used)),
            windowMinutes: integer(object["window_minutes"]),
            resetsAt: date(object["resets_at"])
        )
    }

    nonisolated private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    nonisolated private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    nonisolated private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    nonisolated private static func date(_ value: Any?) -> Date? {
        if let seconds = number(value) { return Date(timeIntervalSince1970: seconds) }
        guard let value = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: value) { return parsed }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}
