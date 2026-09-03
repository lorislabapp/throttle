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

    /// The scope that actually selects rows, falling back to the documented
    /// default when a derived token selects none.
    ///
    /// Deriving a token from a display name narrows the silent zero but cannot
    /// close it: `"Claude Zephyr Preview"` yields `preview`, `"Claude Zen
    /// Extended"` yields `extended`, and neither word appears in any model id.
    /// `Character.isLetter` is true for CJK and Cyrillic too, so a non-Latin
    /// display name produces a token that cannot occur in an ASCII id at all.
    /// No amount of string work can tell — only the database can.
    ///
    /// So: if the token selects nothing over a window that *does* hold events,
    /// it matched nothing, and reporting an untouched week would be the exact
    /// lie this window was fixed for. Fall back to the default, and let
    /// `ScopedCapModel` say so rather than swallowing it.
    ///
    /// Cost is one COUNT-shaped SUM over a timestamp-indexed window, and only
    /// for `.nameToken` — the case that exists solely because Throttle met a
    /// family it does not know. It runs on the snapshot timer, not per frame.
    static func resolveScope(
        in database: Database,
        kind: WindowKind,
        now: Date = Date(),
        scoped: ScopedCapModel.Match
    ) throws -> ScopedCapModel.Match {
        guard kind == .weeklySonnet, case .nameToken = scoped else { return scoped }
        let cutoff = Int64(now.timeIntervalSince1970) - duration(of: kind)
        guard try DatabaseQueries.totalTokens(in: database, sinceTimestamp: cutoff, scoped: scoped) == 0
        else { return scoped }
        // An empty window is empty for every scope; that is not a failed match.
        guard try DatabaseQueries.totalTokens(in: database, sinceTimestamp: cutoff) > 0
        else { return scoped }
        return .family(.sonnet)
    }

    static func duration(of kind: WindowKind) -> Int64 {
        switch kind {
        case .session5h: return session5hSeconds
        case .weeklyAll, .weeklySonnet: return weeklySeconds
        }
    }
}
