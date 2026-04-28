import XCTest
import GRDB
@testable import Throttle

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
        let db = try makeDatabase(events: [
            (60, "claude-opus", 100),       // within 5h
            (3 * 3600, "claude-sonnet", 200), // within 5h
            (6 * 3600, "claude-opus", 50)   // outside 5h
        ])
        let total = try db.read { db in
            try WindowCalculator.totalForWindow(in: db, kind: .session5h)
        }
        XCTAssertEqual(total, 300)
    }

    func test_weeklyAll_sumsLastSevenDays_excludingOlder() throws {
        let day: Int = 24 * 3600
        let db = try makeDatabase(events: [
            (1 * day, "claude-opus-4-7", 1000),    // within 7d
            (6 * day, "claude-sonnet-4-6", 500),   // within 7d
            (8 * day, "claude-opus-4-7", 9999)     // outside 7d
        ])
        let total = try db.read { db in
            try WindowCalculator.totalForWindow(in: db, kind: .weeklyAll)
        }
        XCTAssertEqual(total, 1500, "Weekly window must be true rolling 7-day; older events excluded.")
    }

    func test_weeklySonnet_filtersByModel() throws {
        let db = try makeDatabase(events: [
            (3600, "claude-opus-4-7", 1000),
            (3600, "claude-sonnet-4-6", 500),
            (3600, "claude-haiku-4-5", 100)
        ])
        let total = try db.read { db in
            try WindowCalculator.totalForWindow(in: db, kind: .weeklySonnet)
        }
        XCTAssertEqual(total, 500)
    }

    // MARK: - secondsUntilReset

    func test_session5h_resetMatchesOldestEventPlusFiveHours() throws {
        let db = try makeDatabase(events: [
            (3 * 3600, "claude-opus", 100),  // 3h ago → resets in ~2h
            (60, "claude-opus", 50)
        ])
        let secs = try db.read { db in
            try WindowCalculator.secondsUntilReset(in: db, kind: .session5h)
        }
        // Oldest event is 3h ago, +5h window = +2h from now. Allow ±60s for test runtime.
        XCTAssertEqual(Double(secs), 2 * 3600, accuracy: 60)
    }

    func test_weeklyAll_resetUsesRollingWindow_notFixedAnchor() throws {
        let day: Int = 24 * 3600
        let db = try makeDatabase(events: [
            (6 * day, "claude-opus-4-7", 1000),  // 6d ago → resets in ~1d
            (1 * day, "claude-sonnet-4-6", 200)
        ])
        let secs = try db.read { db in
            try WindowCalculator.secondsUntilReset(in: db, kind: .weeklyAll)
        }
        // Oldest event is 6d ago, +7d window = +1d from now. Allow ±5min.
        XCTAssertEqual(Double(secs), Double(day), accuracy: 300)
    }

    func test_weeklySonnet_resetIgnoresNonSonnetEvents() throws {
        let day: Int = 24 * 3600
        let db = try makeDatabase(events: [
            (6 * day, "claude-opus-4-7", 1000),    // older but ignored
            (2 * day, "claude-sonnet-4-6", 500)    // oldest sonnet → resets in ~5d
        ])
        let secs = try db.read { db in
            try WindowCalculator.secondsUntilReset(in: db, kind: .weeklySonnet)
        }
        XCTAssertEqual(Double(secs), Double(5 * day), accuracy: 300)
    }

    func test_emptyWindow_returnsFullDuration() throws {
        let db = try makeDatabase(events: [])
        let session = try db.read { try WindowCalculator.secondsUntilReset(in: $0, kind: .session5h) }
        let weekly = try db.read { try WindowCalculator.secondsUntilReset(in: $0, kind: .weeklyAll) }
        XCTAssertEqual(session, WindowCalculator.session5hSeconds)
        XCTAssertEqual(weekly, WindowCalculator.weeklySeconds)
    }
}
