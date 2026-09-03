import GRDB
@testable import Throttle
import XCTest

final class WindowCalculatorTests: XCTestCase {
    /// The scope probe memoises per process; each test builds its own database.
    override func setUp() {
        super.setUp()
        WindowCalculator.resetScopeProbeCache()
    }

    private func makeDatabase(events: [(seconds_ago: Int, model: String, tokens: Int)]) throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try Migrations.register(on: db)
        let now = Int64(Date().timeIntervalSince1970)
        try db.write { db in
            for e in events {
                var ev = UsageEvent(
                    id: nil, sessionId: "s1",
                    timestamp: now - Int64(e.seconds_ago),
                    model: e.model,
                    inputTokens: e.tokens, outputTokens: 0,
                    cacheCreate: 0, cacheRead: 0, serviceTier: nil
                )
                try ev.insert(db)
            }
        }
        return db
    }

    // MARK: - totalForWindow

    func test_session5h_sumsLastFiveHours() throws {
        let queue = try makeDatabase(events: [
            (60, "claude-opus", 100),       // within 5h
            (3 * 3600, "claude-sonnet", 200), // within 5h
            (6 * 3600, "claude-opus", 50)   // outside 5h
        ])
        let total = try queue.read { database in
            try WindowCalculator.totalForWindow(in: database, kind: .session5h)
        }
        XCTAssertEqual(total, 300)
    }

    func test_weeklyAll_sumsLastSevenDays_excludingOlder() throws {
        let day: Int = 24 * 3600
        let queue = try makeDatabase(events: [
            (1 * day, "claude-opus-4-7", 1000),    // within 7d
            (6 * day, "claude-sonnet-4-6", 500),   // within 7d
            (8 * day, "claude-opus-4-7", 9999)     // outside 7d
        ])
        let total = try queue.read { database in
            try WindowCalculator.totalForWindow(in: database, kind: .weeklyAll)
        }
        XCTAssertEqual(total, 1500, "Weekly window must be true rolling 7-day; older events excluded.")
    }

    /// The scope is passed in, never inherited. The test bundle is hosted by
    /// Throttle.app, so `ScopedCapModel`'s default would read the *developer's*
    /// real `com.lorislab.throttle` preferences — on the machine this was found,
    /// a cap scoped to Fable, which made this assertion machine-dependent.
    func test_weeklySonnet_filtersByModel() throws {
        let queue = try makeDatabase(events: [
            (3600, "claude-opus-4-7", 1000),
            (3600, "claude-sonnet-4-6", 500),
            (3600, "claude-haiku-4-5", 100)
        ])
        let total = try queue.read { database in
            try WindowCalculator.totalForWindow(in: database, kind: .weeklySonnet, scoped: .family(.sonnet))
        }
        XCTAssertEqual(total, 500)
    }

    /// The scoped cap is whatever Anthropic says it is, and Fable and Mythos are
    /// one family. A filter built from the *word* "Fable" cannot see a
    /// `claude-mythos-*` id; a filter built from the family can.
    func test_weeklySonnet_scopedToFable_countsMythosToo() throws {
        let queue = try makeDatabase(events: [
            (3600, "claude-fable-5", 700),
            (3600, "claude-mythos-5", 300),
            (3600, "claude-sonnet-4-6", 500),
            (3600, "claude-opus-4-7", 1000)
        ])
        let total = try queue.read { database in
            try WindowCalculator.totalForWindow(in: database, kind: .weeklySonnet, scoped: .family(.fable))
        }
        XCTAssertEqual(total, 1000, "the scoped family must include its aliases, not just its name")
    }

    /// The display name is prose; the model column holds ids. `"Claude Sonnet 4.6"`
    /// as a raw `LIKE '%claude sonnet 4.6%'` matched no row at all — and matching
    /// nothing reads as 0% used on the one window that means "you are out".
    func test_weeklySonnet_displayNameThatIsNotABareFamilyWord_stillMatches() throws {
        let queue = try makeDatabase(events: [
            (3600, "claude-sonnet-4-6", 500),
            (3600, "claude-opus-4-7", 1000)
        ])
        for name in ["Claude Sonnet 4.6", "Sonnet 4.6", "sonnet"] {
            XCTAssertEqual(ScopedCapModel.match(forDisplayName: name), .family(.sonnet), name)
            let total = try queue.read { database in
                try WindowCalculator.totalForWindow(
                    in: database, kind: .weeklySonnet, scoped: ScopedCapModel.match(forDisplayName: name))
            }
            XCTAssertEqual(total, 500, "\(name) must select the Sonnet events")
        }
    }

    /// A family Throttle has no rule for yet must still be counted. The token is
    /// *derived*, never the whole display name: `"Claude Zephyr 1.0"` used
    /// literally would be `LIKE '%claude zephyr 1.0%'` against `claude-zephyr-1`
    /// — the same silent zero this window was fixed for, kept alive for the next
    /// family Throttle meets.
    func test_weeklySonnet_unknownFamily_fallsBackToMatchingTheName() throws {
        let queue = try makeDatabase(events: [
            (3600, "claude-zephyr-1", 400),
            (3600, "claude-sonnet-4-6", 500)
        ])
        for name in ["Zephyr", "Claude Zephyr 1.0", "Zephyr 1.0", "claude-zephyr-1"] {
            let match = ScopedCapModel.match(forDisplayName: name)
            XCTAssertEqual(match, .nameToken("zephyr"), name)
            let total = try queue.read { database in
                try WindowCalculator.totalForWindow(in: database, kind: .weeklySonnet, scoped: match)
            }
            XCTAssertEqual(total, 400, "\(name) must reach the zephyr events")
        }
    }

    /// The other direction of the same hazard: a name that survives as a token
    /// matching *everything* would charge the whole account against a per-model
    /// cap. Nothing usable in the name means the documented default, never a
    /// filter that matches every row.
    func test_weeklySonnet_vendorOnlyName_doesNotMatchEveryModel() throws {
        let queue = try makeDatabase(events: [
            (3600, "claude-sonnet-4-6", 500),
            (3600, "claude-opus-4-7", 1000),
            (3600, "claude-haiku-4-5", 100)
        ])
        for name in ["Claude", "claude", "4.7", "—"] {
            let match = ScopedCapModel.match(forDisplayName: name)
            XCTAssertEqual(match, .family(.sonnet), name)
            let total = try queue.read { database in
                try WindowCalculator.totalForWindow(in: database, kind: .weeklySonnet, scoped: match)
            }
            XCTAssertEqual(total, 500, "\(name) must not sweep in every model")
        }
    }

    /// The scoped window is a *filter*. If it ever equals the all-model total on
    /// a fixture holding other families, it has stopped filtering — which is how
    /// a name that matches everything, or a `.other` tier degrading to "no
    /// clause", would present.
    func test_weeklySonnet_isAlwaysNarrowerThanWeeklyAll() throws {
        let queue = try makeDatabase(events: [
            (3600, "claude-sonnet-4-6", 500),
            (3600, "claude-opus-4-7", 1000),
            (3600, "claude-fable-5", 700),
            (3600, "claude-zephyr-1", 400)
        ])
        let all = try queue.read { database in
            try WindowCalculator.totalForWindow(in: database, kind: .weeklyAll)
        }
        XCTAssertEqual(all, 2600)
        let scopes: [ScopedCapModel.Match] = [
            .family(.sonnet), .family(.opus), .family(.fable), .nameToken("zephyr")
        ]
        for scope in scopes {
            let total = try queue.read { database in
                try WindowCalculator.totalForWindow(in: database, kind: .weeklySonnet, scoped: scope)
            }
            XCTAssertGreaterThan(total, 0, "\(scope) must select its own events")
            XCTAssertLessThan(total, all, "\(scope) must not select every model")
        }
    }

    /// Deriving a token narrows the silent zero; it cannot close it. `"Claude
    /// Zephyr Preview"` yields `preview`, which is a real word absent from every
    /// model id, and a non-Latin name yields a token that cannot occur in an
    /// ASCII id at all. Only the query can tell, so the query decides.
    func test_weeklySonnet_tokenThatMatchesNothing_fallsBackToTheDefault() throws {
        let queue = try makeDatabase(events: [
            (3600, "claude-sonnet-4-6", 500),
            (3600, "claude-opus-4-7", 1000)
        ])
        for name in ["Claude Zephyr Preview", "Claude Zen Extended", "クロード"] {
            let stated = ScopedCapModel.match(forDisplayName: name)
            let resolved = try queue.read { database in
                try WindowCalculator.resolveScope(in: database, kind: .weeklySonnet, scoped: stated)
            }
            XCTAssertEqual(resolved, .family(.sonnet), "\(name) matched nothing; use the default")
            let total = try queue.read { database in
                try WindowCalculator.totalForWindow(in: database, kind: .weeklySonnet, scoped: resolved)
            }
            XCTAssertEqual(total, 500, "\(name) must not report an untouched week")
        }
    }

    /// The case the first version of this guard got wrong. A user on an
    /// unknown-family cap who used that model before this week and none of it
    /// this week is indistinguishable, within the window, from a broken token —
    /// and rewriting their scope would hand them the whole week's Sonnet total
    /// under a cap scoped to something else. A loud wrong percentage is worse
    /// than the silent zero it replaced. The unbounded question separates them.
    func test_weeklySonnet_usedBeforeButNotThisWeek_isARealZeroNotABrokenToken() throws {
        let day: Int = 24 * 3600
        let queue = try makeDatabase(events: [
            (10 * day, "claude-zephyr-1", 900),   // used, but outside the window
            (3600, "claude-sonnet-4-6", 500)      // this week, a different model
        ])
        let stated = ScopedCapModel.match(forDisplayName: "Zephyr")
        let resolved = try queue.read { database in
            try WindowCalculator.resolveScope(in: database, kind: .weeklySonnet, scoped: stated)
        }
        XCTAssertEqual(resolved, stated, "a quiet week is not a broken token")
        let total = try queue.read { database in
            try WindowCalculator.totalForWindow(in: database, kind: .weeklySonnet, scoped: resolved)
        }
        XCTAssertEqual(total, 0, "0% of Zephyr used — not the Sonnet total under a Zephyr cap")
    }

    /// A token that DOES match must not be second-guessed into the default.
    func test_weeklySonnet_tokenThatMatches_isKept() throws {
        let queue = try makeDatabase(events: [
            (3600, "claude-zephyr-1", 400),
            (3600, "claude-sonnet-4-6", 500)
        ])
        let stated = ScopedCapModel.match(forDisplayName: "Claude Zephyr 1.0")
        let resolved = try queue.read { database in
            try WindowCalculator.resolveScope(in: database, kind: .weeklySonnet, scoped: stated)
        }
        XCTAssertEqual(resolved, stated)
    }

    /// An empty window is empty for every scope. That is not a failed match, and
    /// treating it as one would rewrite the scope of every quiet week.
    func test_weeklySonnet_emptyWindow_doesNotCountAsAFailedMatch() throws {
        let queue = try makeDatabase(events: [])
        let stated = ScopedCapModel.match(forDisplayName: "Claude Zephyr Preview")
        let resolved = try queue.read { database in
            try WindowCalculator.resolveScope(in: database, kind: .weeklySonnet, scoped: stated)
        }
        XCTAssertEqual(resolved, stated)
    }

    /// Nothing stated yet: keep computing the window this install always computed.
    func test_weeklySonnet_unstatedScope_defaultsToSonnet() {
        XCTAssertEqual(ScopedCapModel.match(forDisplayName: nil), .family(.sonnet))
        XCTAssertEqual(ScopedCapModel.match(forDisplayName: ""), .family(.sonnet))
    }

    // MARK: - secondsUntilReset

    func test_session5h_resetMatchesOldestEventPlusFiveHours() throws {
        let queue = try makeDatabase(events: [
            (3 * 3600, "claude-opus", 100),  // 3h ago → resets in ~2h
            (60, "claude-opus", 50)
        ])
        let secs = try queue.read { database in
            try WindowCalculator.secondsUntilReset(in: database, kind: .session5h)
        }
        // Oldest event is 3h ago, +5h window = +2h from now. Allow ±60s for test runtime.
        XCTAssertEqual(Double(secs), 2 * 3600, accuracy: 60)
    }

    func test_weeklyAll_resetUsesRollingWindow_notFixedAnchor() throws {
        let day: Int = 24 * 3600
        let queue = try makeDatabase(events: [
            (6 * day, "claude-opus-4-7", 1000),  // 6d ago → resets in ~1d
            (1 * day, "claude-sonnet-4-6", 200)
        ])
        let secs = try queue.read { database in
            try WindowCalculator.secondsUntilReset(in: database, kind: .weeklyAll)
        }
        // Oldest event is 6d ago, +7d window = +1d from now. Allow ±5min.
        XCTAssertEqual(Double(secs), Double(day), accuracy: 300)
    }

    func test_weeklySonnet_resetIgnoresNonSonnetEvents() throws {
        let day: Int = 24 * 3600
        let queue = try makeDatabase(events: [
            (6 * day, "claude-opus-4-7", 1000),    // older but ignored
            (2 * day, "claude-sonnet-4-6", 500)    // oldest sonnet → resets in ~5d
        ])
        let secs = try queue.read { database in
            try WindowCalculator.secondsUntilReset(in: database, kind: .weeklySonnet, scoped: .family(.sonnet))
        }
        XCTAssertEqual(Double(secs), Double(5 * day), accuracy: 300)
    }

    func test_emptyWindow_returnsFullDuration() throws {
        let queue = try makeDatabase(events: [])
        let session = try queue.read { try WindowCalculator.secondsUntilReset(in: $0, kind: .session5h) }
        let weekly = try queue.read { try WindowCalculator.secondsUntilReset(in: $0, kind: .weeklyAll) }
        XCTAssertEqual(session, WindowCalculator.session5hSeconds)
        XCTAssertEqual(weekly, WindowCalculator.weeklySeconds)
    }
}
