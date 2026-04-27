import XCTest
import GRDB
@testable import Throttle

final class DatabaseQueriesTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try Migrations.register(on: db)
        return db
    }

    func test_insertEvents_thenSumAfterTimestamp() throws {
        let db = try makeDatabase()
        let now = Int64(Date().timeIntervalSince1970)
        try db.write { db in
            for i in 0..<5 {
                var ev = UsageEvent(
                    id: nil, sessionId: "s1",
                    timestamp: now - Int64(i * 60),
                    model: "claude-sonnet-4-6",
                    inputTokens: 100, outputTokens: 50,
                    cacheCreate: 0, cacheRead: 0, serviceTier: nil
                )
                try ev.insert(db)
            }
        }
        let total = try db.read { db in
            try DatabaseQueries.totalTokens(in: db, sinceTimestamp: now - 200)
        }
        // 4 events within 200s window (i=0..3 → offsets 0,60,120,180), each 150 tokens
        XCTAssertEqual(total, 600)
    }

    func test_upsertCalibration_replacesOnConflict() throws {
        let db = try makeDatabase()
        try db.write { db in
            try DatabaseQueries.upsertCalibration(
                in: db, kind: .session5h, capTokens: 1000, source: "auto")
            try DatabaseQueries.upsertCalibration(
                in: db, kind: .session5h, capTokens: 2000, source: "manual")
        }
        let cal = try db.read { db in
            try DatabaseQueries.calibration(in: db, kind: .session5h)
        }
        XCTAssertEqual(cal?.capTokens, 2000)
        XCTAssertEqual(cal?.source, "manual")
    }
}
