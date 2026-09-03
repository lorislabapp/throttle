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
    /// ## The question this asks, and the one it must not ask
    ///
    /// "Selected nothing *this week* while other models did" does not mean the
    /// token is broken. It is exactly what a real user on an unknown-family cap
    /// looks like when they simply did not touch that model for seven days.
    /// Treating that as a token failure would hand them the whole week's Sonnet
    /// total under a cap scoped to something else — trading a silent zero for a
    /// loud wrong percentage — and it would flap: seven quiet days would flip
    /// the scope on a file-watcher tick and jump the bar from ~0 to the Sonnet
    /// total.
    ///
    /// The question that actually separates the two cases is unbounded: has
    /// this token **ever** matched a row? "Never, in the whole table" is a
    /// broken token. "Matched before, not this week" is a genuine zero and must
    /// render as one. That also removes the flap by construction — the answer
    /// cannot change because a week went quiet.
    ///
    /// Cost: the windowed total is checked first, so the unbounded existence
    /// probe only runs on a window that is already empty for this scope, and
    /// only for `.nameToken` — the case that exists solely because Throttle met
    /// a family it does not know. `LIMIT 1` stops at the first match.
    static func resolveScope(
        in database: Database,
        kind: WindowKind,
        now: Date = Date(),
        scoped: ScopedCapModel.Match
    ) throws -> ScopedCapModel.Match {
        guard kind == .weeklySonnet, case .nameToken = scoped else { return scoped }
        let cutoff = Int64(now.timeIntervalSince1970) - duration(of: kind)
        // Anything selected in the window proves the token matches — and is also
        // how a token that only started matching recently re-earns its scope, so
        // the memo below is refreshed here rather than pinned for the process.
        guard try DatabaseQueries.totalTokens(in: database, sinceTimestamp: cutoff, scoped: scoped) == 0
        else {
            ScopeProbeMemo.store(true, for: scoped)
            return scoped
        }
        if let remembered = ScopeProbeMemo.matched(for: scoped) {
            return remembered ? scoped : .family(.sonnet)
        }
        // An empty table proves nothing about the token either way, and must not
        // be memoised — the table fills up.
        guard try DatabaseQueries.hasAnyEvent(in: database, scoped: nil) else { return scoped }
        let everMatched = try DatabaseQueries.hasAnyEvent(in: database, scoped: scoped)
        ScopeProbeMemo.store(everMatched, for: scoped)
        return everMatched ? scoped : .family(.sonnet)
    }

    /// Forget the memoised probe answers. Tests only: each builds its own
    /// database, and a process-lifetime memo would leak between them.
    static func resetScopeProbeCache() { ScopeProbeMemo.reset() }

    /// The scope for `kind`, already checked against the database.
    ///
    /// One place, so a caller cannot compute a numerator under one scope while
    /// the cap it is divided by was calibrated under another — which is what
    /// `CalibrationEngine` was doing while `AppState` resolved and it did not.
    /// Returns both the scope the server states and the one the database
    /// supports, so a caller can tell the two apart without reading the global
    /// a second time — the read the comment above was written to remove.
    static func resolvedScope(
        in database: Database,
        kind: WindowKind,
        now: Date = Date()
    ) throws -> (stated: ScopedCapModel.Match, resolved: ScopedCapModel.Match) {
        let stated = kind == .weeklySonnet ? ScopedCapModel.match : ScopedCapModel.Match.family(.sonnet)
        return (stated, try resolveScope(in: database, kind: kind, now: now, scoped: stated))
    }

    static func duration(of kind: WindowKind) -> Int64 {
        switch kind {
        case .session5h: return session5hSeconds
        case .weeklyAll, .weeklySonnet: return weeklySeconds
        }
    }
}

/// Memo for the unbounded existence probe.
///
/// `lower(model) LIKE '%…%'` cannot use the timestamp index, and for the broken
/// token nothing matches, so `LIMIT 1` never short-circuits and the probe is a
/// full table scan — measured elsewhere in this app at ~438 ms cold over 682 k
/// rows. That user's windowed total is *always* zero, and `refresh()` is driven
/// by the file watcher, so without this it would run on every transcript write.
///
/// "Has this token ever matched" does not change often enough to re-derive per
/// write. A token that starts matching is caught by the windowed check ahead of
/// the memo, which refreshes it.
private enum ScopeProbeMemo {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var key: ScopedCapModel.Match?
    nonisolated(unsafe) private static var value: Bool?

    static func matched(for match: ScopedCapModel.Match) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return key == match ? value : nil
    }

    static func store(_ matched: Bool, for match: ScopedCapModel.Match) {
        lock.lock(); defer { lock.unlock() }
        key = match; value = matched
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        key = nil; value = nil
    }
}
