import GRDB
@testable import Throttle
import XCTest

final class WindowCalculatorTests: XCTestCase {
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

    /// A family Throttle has no rule for yet must still be counted — falling back
    /// to the name inside the id beats reporting an untouched week.
    func test_weeklySonnet_unknownFamily_fallsBackToMatchingTheName() throws {
        let queue = try makeDatabase(events: [
            (3600, "claude-zephyr-1", 400),
            (3600, "claude-sonnet-4-6", 500)
        ])
        let match = ScopedCapModel.match(forDisplayName: "Zephyr")
        XCTAssertEqual(match, .nameToken("zephyr"))
        let total = try queue.read { database in
            try WindowCalculator.totalForWindow(in: database, kind: .weeklySonnet, scoped: match)
        }
        XCTAssertEqual(total, 400)
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
