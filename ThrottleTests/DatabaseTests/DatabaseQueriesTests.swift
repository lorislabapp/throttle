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

    func test_totalTokens_weightsCacheReadAtOneTenth() throws {
        let db = try makeDatabase()
        let now = Int64(Date().timeIntervalSince1970)
        try db.write { db in
            // 100 input + 50 output + 200 cache_create + 1000 cache_read.
            // Weighted: 100 + 50 + 200 + (1000 / 10) = 450.
            var ev = UsageEvent(
                id: nil, sessionId: "s1",
                timestamp: now - 60,
                model: "claude-sonnet-4-6",
                inputTokens: 100, outputTokens: 50,
                cacheCreate: 200, cacheRead: 1000, serviceTier: nil
            )
            try ev.insert(db)
        }
        let total = try db.read { db in
            try DatabaseQueries.totalTokens(in: db, sinceTimestamp: now - 200)
        }
        XCTAssertEqual(total, 450, "cache_read must be weighted at 1/10 to match Anthropic billing.")
    }

    func test_totalTokens_modelTier_appliesWeightedSum() throws {
        let db = try makeDatabase()
        let now = Int64(Date().timeIntervalSince1970)
        try db.write { db in
            var sonnet = UsageEvent(
                id: nil, sessionId: "s1", timestamp: now - 30,
                model: "claude-sonnet-4-6",
                inputTokens: 100, outputTokens: 0,
                cacheCreate: 0, cacheRead: 500, serviceTier: nil
            )
            try sonnet.insert(db)
            var opus = UsageEvent(
                id: nil, sessionId: "s2", timestamp: now - 30,
                model: "claude-opus-4-7",
                inputTokens: 100, outputTokens: 0,
                cacheCreate: 0, cacheRead: 500, serviceTier: nil
            )
            try opus.insert(db)
        }
        let sonnetTotal = try db.read { db in
            try DatabaseQueries.totalTokens(in: db, sinceTimestamp: now - 200, modelTier: .sonnet)
        }
        // 100 + (500 / 10) = 150
        XCTAssertEqual(sonnetTotal, 150)
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
