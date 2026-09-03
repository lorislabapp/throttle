import Foundation
import GRDB

enum WindowCalculator {
    static let session5hSeconds: Int64 = 5 * 3600
    static let weeklySeconds: Int64 = 7 * 24 * 3600

    /// Total tokens consumed in the rolling window for the given kind.
    /// All windows are true rolling: cutoff = now - windowDuration.
    /// (The previous fixed-anchor model for weekly windows produced reset
    ///  times that drifted from claude.ai's rolling-window semantics.)
    /// `scoped` defaults to whatever the server last told this install, but is a
    /// parameter rather than a global read: the window is otherwise a pure
    /// function of the database, and a number this load-bearing should not
    /// silently depend on a preferences file. (It did — and because the test
    /// bundle is hosted by the app, these tests were reading the developer's
    /// real `com.lorislab.throttle` domain and computing a Fable-scoped window
    /// over Sonnet fixtures.)
    static func totalForWindow(
        in database: Database,
        kind: WindowKind,
        now: Date = Date(),
        scoped: ScopedCapModel.Match = ScopedCapModel.match
    ) throws -> Int {
        let cutoff = Int64(now.timeIntervalSince1970) - duration(of: kind)
        switch kind {
        case .session5h, .weeklyAll:
            return try DatabaseQueries.totalTokens(in: database, sinceTimestamp: cutoff)
        case .weeklySonnet:
            // Whichever model the account's scoped cap belongs to — not a
            // constant. See `ScopedCapModel`.
            return try DatabaseQueries.totalTokens(in: database, sinceTimestamp: cutoff, scoped: scoped)
        }
    }

    /// Seconds remaining until the next reset for the given window kind.
    /// For every window: reset = (earliest billable event in window) + windowDuration - now.
    /// For the scoped weekly window, "billable" is filtered to the model the
    /// server scoped the cap to (`ScopedCapModel`); otherwise, any model.
    static func secondsUntilReset(
        in database: Database,
        kind: WindowKind,
        now: Date = Date(),
        scoped: ScopedCapModel.Match = ScopedCapModel.match
    ) throws -> Int64 {
        let nowSec = Int64(now.timeIntervalSince1970)
        let windowSec = duration(of: kind)
        let cutoff = nowSec - windowSec

        // Same clause builder the total uses, so the two cannot disagree about
        // which events are billable.
        let clause: (sql: String, args: [any DatabaseValueConvertible])
        switch kind {
        case .session5h, .weeklyAll:
            clause = ("", [])
        case .weeklySonnet:
            clause = DatabaseQueries.scopedClause(scoped)
        }

        var args: [any DatabaseValueConvertible] = [cutoff]
        args += clause.args
        let earliest = try Int64.fetchOne(database, sql: """
            SELECT MIN(timestamp) FROM usage_events WHERE timestamp > ?\(clause.sql)
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
