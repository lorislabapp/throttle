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
}
