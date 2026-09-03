import GRDB
@testable import Throttle
import XCTest

final class DatabaseQueriesTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Migrations.register(on: queue)
        return queue
    }

    func test_insertEvents_thenSumAfterTimestamp() throws {
        let queue = try makeDatabase()
        let now = Int64(Date().timeIntervalSince1970)
        try queue.write { database in
            for i in 0..<5 {
                var ev = UsageEvent(
                    id: nil, sessionId: "s1",
                    timestamp: now - Int64(i * 60),
                    model: "claude-sonnet-4-6",
                    inputTokens: 100, outputTokens: 50,
                    cacheCreate: 0, cacheRead: 0, serviceTier: nil
                )
                try ev.insert(database)
            }
        }
        let total = try queue.read { database in
            try DatabaseQueries.totalTokens(in: database, sinceTimestamp: now - 200)
        }
        // 4 events within 200s window (i=0..3 → offsets 0,60,120,180), each 150 tokens
        XCTAssertEqual(total, 600)
    }

    func test_totalTokens_weightsCacheReadAtOneTenth() throws {
        let queue = try makeDatabase()
        let now = Int64(Date().timeIntervalSince1970)
        try queue.write { database in
            // 100 input + 50 output + 200 cache_create + 1000 cache_read.
            // Weighted: 100 + 50 + 200 + (1000 / 10) = 450.
            var ev = UsageEvent(
                id: nil, sessionId: "s1",
                timestamp: now - 60,
                model: "claude-sonnet-4-6",
                inputTokens: 100, outputTokens: 50,
                cacheCreate: 200, cacheRead: 1000, serviceTier: nil
            )
            try ev.insert(database)
        }
        let total = try queue.read { database in
            try DatabaseQueries.totalTokens(in: database, sinceTimestamp: now - 200)
        }
        XCTAssertEqual(total, 450, "cache_read must be weighted at 1/10 to match Anthropic billing.")
    }

    func test_totalTokens_modelTier_appliesWeightedSum() throws {
        let queue = try makeDatabase()
        let now = Int64(Date().timeIntervalSince1970)
        try queue.write { database in
            var sonnet = UsageEvent(
                id: nil, sessionId: "s1", timestamp: now - 30,
                model: "claude-sonnet-4-6",
                inputTokens: 100, outputTokens: 0,
                cacheCreate: 0, cacheRead: 500, serviceTier: nil
            )
            try sonnet.insert(database)
            var opus = UsageEvent(
                id: nil, sessionId: "s2", timestamp: now - 30,
                model: "claude-opus-4-7",
                inputTokens: 100, outputTokens: 0,
                cacheCreate: 0, cacheRead: 500, serviceTier: nil
            )
            try opus.insert(database)
        }
        let sonnetTotal = try queue.read { database in
            try DatabaseQueries.totalTokens(in: database, sinceTimestamp: now - 200, modelTier: .sonnet)
        }
        // 100 + (500 / 10) = 150
        XCTAssertEqual(sonnetTotal, 150)
    }

    func test_upsertCalibration_replacesOnConflict() throws {
        let queue = try makeDatabase()
        try queue.write { database in
            try DatabaseQueries.upsertCalibration(
                in: database, kind: .session5h, capTokens: 1000, source: "auto")
            try DatabaseQueries.upsertCalibration(
                in: database, kind: .session5h, capTokens: 2000, source: "manual")
        }
        let cal = try queue.read { database in
            try DatabaseQueries.calibration(in: database, kind: .session5h)
        }
        XCTAssertEqual(cal?.capTokens, 2000)
        XCTAssertEqual(cal?.source, "manual")
    }

    /// The grouping IS the rate-weighting fix. Without `GROUP BY`, SQLite
    /// happily returns one row of bare aggregates, every family collapses into
    /// whichever `model` the engine picks, and nothing downstream notices —
    /// `isUpperBound` would then compare rate-blind sums again.
    func test_composition_groupsEachFamilySeparately() throws {
        let queue = try makeDatabase()
        let now = Int64(Date().timeIntervalSince1970)
        try queue.write { database in
            var sonnet = UsageEvent(
                id: nil, sessionId: "s1", timestamp: now - 60,
                model: "claude-sonnet-4-6",
                inputTokens: 1_000, outputTokens: 10,
                cacheCreate: 20, cacheRead: 300, serviceTier: nil
            )
            try sonnet.insert(database)
            var fable = UsageEvent(
                id: nil, sessionId: "s1", timestamp: now - 120,
                model: "claude-mythos-5",
                inputTokens: 7, outputTokens: 4_000,
                cacheCreate: 0, cacheRead: 0, serviceTier: nil
            )
            try fable.insert(database)
        }
        let byFamily = try queue.read { try StatsDataService.composition(in: $0, range: .last7d) }

        XCTAssertEqual(byFamily.count, 2, "one row per family, not one row of totals")
        XCTAssertEqual(byFamily[.sonnet],
                       .init(input: 1_000, output: 10, cacheCreate: 20, cacheRead: 300))
        // `claude-mythos-5` must land in `.fable`, the alias the bucket rule owns.
        XCTAssertEqual(byFamily[.fable],
                       .init(input: 7, output: 4_000, cacheCreate: 0, cacheRead: 0))
        XCTAssertNil(byFamily[.opus])

        // And the whole point: rate-weighted, this pair is not a bound, while
        // the same columns summed flat (1.2*1007 + 0.95*20 + 0.12*300 = 1263.4
        // vs 2.8*4010 = 11228) would also fail — so use a pair that only the
        // grouping separates: Sonnet input against Fable output.
        XCTAssertFalse(PlanAdvisor.isUpperBound(byFamily))
    }
}
