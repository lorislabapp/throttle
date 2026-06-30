import XCTest
import GRDB
@testable import Throttle

final class CalibrationEngineTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try Migrations.register(on: db)
        return db
    }

    func test_anchorAt90Percent_setsCapFromObservedTotal() throws {
        let db = try makeDatabase()
        try db.write { db in
            // Pretend the user has consumed 18,000 tokens this weekly window.
            // Timestamps must be DISTINCT: the v6 UNIQUE natural key
            // (session_id, timestamp, model, …) + INSERT OR IGNORE dedupes
            // identical rows, so same-timestamp inserts would collapse to one.
            let base = Int64(Date().timeIntervalSince1970)
            for i in 0..<10 {
                var ev = UsageEvent(
                    id: nil, sessionId: "s",
                    timestamp: base - Int64(i),   // distinct, all within the weekly window
                    model: "claude-sonnet-4-6",
                    inputTokens: 1800, outputTokens: 0,
                    cacheCreate: 0, cacheRead: 0, serviceTier: nil
                )
                try ev.insert(db)
            }
        }
        try db.write { db in
            try CalibrationEngine.anchor(
                in: db, kind: .weeklyAll, observedPercent: 90)
        }
        let cal = try db.read { db in
            try DatabaseQueries.calibration(in: db, kind: .weeklyAll)
        }
        XCTAssertNotNil(cal)
        XCTAssertEqual(cal?.source, "anchor_90")
        // 18,000 / 0.9 = 20,000
        XCTAssertEqual(cal?.capTokens, 20_000)
    }

    func test_manualOverride_replacesAnyExisting() throws {
        let db = try makeDatabase()
        try db.write { db in
            try CalibrationEngine.setManual(in: db, kind: .session5h, capTokens: 1_000_000)
        }
        let cal = try db.read { db in
            try DatabaseQueries.calibration(in: db, kind: .session5h)
        }
        XCTAssertEqual(cal?.capTokens, 1_000_000)
        XCTAssertEqual(cal?.source, "manual")
    }
}
