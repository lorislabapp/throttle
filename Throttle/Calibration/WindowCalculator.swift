import Foundation
import GRDB

enum WindowCalculator {
    static let session5hSeconds: Int64 = 5 * 3600

    /// Total tokens consumed in the rolling window for the given kind.
    /// Uses `sinceTimestamp` based on either the rolling cutoff (session_5h)
    /// or the user-configured weekly anchor (weekly_*).
    static func totalForWindow(in db: Database, kind: WindowKind, now: Date = Date()) throws -> Int {
        let nowSec = Int64(now.timeIntervalSince1970)
        switch kind {
        case .session5h:
            return try DatabaseQueries.totalTokens(in: db, sinceTimestamp: nowSec - session5hSeconds)
        case .weeklyAll:
            let cutoff = try weeklyCutoff(in: db, now: now)
            return try DatabaseQueries.totalTokens(in: db, sinceTimestamp: cutoff)
        case .weeklySonnet:
            let cutoff = try weeklyCutoff(in: db, now: now)
            return try DatabaseQueries.totalTokens(in: db, sinceTimestamp: cutoff, modelTier: .sonnet)
        }
    }

    /// Returns the seconds-since-epoch of the most recent weekly reset.
    /// User configures the anchor via `settings.weekly_anchor_iso8601`.
    /// If no anchor is set, defaults to seven days ago.
    static func weeklyCutoff(in db: Database, now: Date = Date()) throws -> Int64 {
        if let iso = try DatabaseQueries.setting(in: db, key: "weekly_anchor_iso8601"),
           let anchor = ISO8601DateFormatter().date(from: iso) {
            // Advance the anchor by 7-day increments until it's <= now.
            var cursor = anchor
            let week: TimeInterval = 7 * 24 * 3600
            while cursor.addingTimeInterval(week) <= now {
                cursor = cursor.addingTimeInterval(week)
            }
            return Int64(cursor.timeIntervalSince1970)
        }
        return Int64(now.timeIntervalSince1970 - 7 * 24 * 3600)
    }

    /// Seconds remaining until the next reset for the given window kind.
    static func secondsUntilReset(in db: Database, kind: WindowKind, now: Date = Date()) throws -> Int64 {
        let nowSec = Int64(now.timeIntervalSince1970)
        switch kind {
        case .session5h:
            // Find the earliest event in the current rolling window.
            let cutoff = nowSec - session5hSeconds
            let earliest = try Int64.fetchOne(db, sql: """
                SELECT MIN(timestamp) FROM usage_events WHERE timestamp > ?
                """, arguments: [cutoff])
            guard let earliest, earliest > 0 else { return session5hSeconds }
            return max(0, (earliest + session5hSeconds) - nowSec)
        case .weeklyAll, .weeklySonnet:
            let cutoff = try weeklyCutoff(in: db, now: now)
            return max(0, (cutoff + 7 * 24 * 3600) - nowSec)
        }
    }
}
