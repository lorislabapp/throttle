import Foundation
import GRDB

enum WindowCalculator {
    static let session5hSeconds: Int64 = 5 * 3600
    static let weeklySeconds: Int64 = 7 * 24 * 3600

    /// Total tokens consumed in the rolling window for the given kind.
    /// All windows are true rolling: cutoff = now - windowDuration.
    /// (The previous fixed-anchor model for weekly windows produced reset
    ///  times that drifted from claude.ai's rolling-window semantics.)
    static func totalForWindow(in db: Database, kind: WindowKind, now: Date = Date()) throws -> Int {
        let cutoff = Int64(now.timeIntervalSince1970) - duration(of: kind)
        switch kind {
        case .session5h, .weeklyAll:
            return try DatabaseQueries.totalTokens(in: db, sinceTimestamp: cutoff)
        case .weeklySonnet:
            // Whichever model the account's scoped cap belongs to — not a
            // constant. See `ScopedCapModel`.
            return try DatabaseQueries.totalTokens(
                in: db, sinceTimestamp: cutoff, modelToken: ScopedCapModel.matchToken)
        }
    }

    /// Seconds remaining until the next reset for the given window kind.
    /// For every window: reset = (earliest billable event in window) + windowDuration - now.
    /// For the scoped weekly window, "billable" is filtered to the model the
    /// server scoped the cap to (`ScopedCapModel`); otherwise, any model.
    static func secondsUntilReset(in db: Database, kind: WindowKind, now: Date = Date()) throws -> Int64 {
        let nowSec = Int64(now.timeIntervalSince1970)
        let windowSec = duration(of: kind)
        let cutoff = nowSec - windowSec

        let modelClause: String
        switch kind {
        case .session5h, .weeklyAll:
            modelClause = ""
        case .weeklySonnet:
            modelClause = " AND lower(model) LIKE ?"
        }

        var args: [any DatabaseValueConvertible] = [cutoff]
        if kind == .weeklySonnet {
            let safe = ScopedCapModel.matchToken.filter { $0 != "%" && $0 != "_" }
            guard !safe.isEmpty else { return windowSec }
            args.append("%" + safe + "%")
        }
        let earliest = try Int64.fetchOne(db, sql: """
            SELECT MIN(timestamp) FROM usage_events WHERE timestamp > ?\(modelClause)
            """, arguments: StatementArguments(args))

        guard let earliest, earliest > 0 else { return windowSec }
        return max(0, (earliest + windowSec) - nowSec)
    }

    static func duration(of kind: WindowKind) -> Int64 {
        switch kind {
        case .session5h: return session5hSeconds
        case .weeklyAll, .weeklySonnet: return weeklySeconds
        }
    }
}
