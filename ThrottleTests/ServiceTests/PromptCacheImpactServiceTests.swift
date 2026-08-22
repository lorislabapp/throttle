import GRDB
@testable import Throttle
import XCTest

final class PromptCacheImpactServiceTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try Migrations.register(on: db)
        return db
    }

    private func insert(
        _ db: Database,
        session: String,
        timestamp: Int64,
        model: String,
        input: Int,
        create: Int,
        read: Int
    ) throws {
        var event = UsageEvent(
            id: nil, sessionId: session, timestamp: timestamp, model: model,
            inputTokens: input, outputTokens: 500, cacheCreate: create,
            cacheRead: read, serviceTier: nil
        )
        try event.insert(db)
    }

    func test_latestUsesLastRequestInputFootprintNotCumulativeSessionTokens() throws {
        let queue = try makeDatabase()
        try queue.write { db in
            try insert(db, session: "s", timestamp: 10, model: "claude-opus", input: 1_000, create: 20_000, read: 40_000)
            try insert(db, session: "s", timestamp: 20, model: "claude-sonnet", input: 2_000, create: 3_000, read: 95_000)
        }

        let impact = try queue.read { try PromptCacheImpactService.latest(in: $0, sessionId: "s") }
        XCTAssertEqual(impact?.contextTokens, 100_000)
        XCTAssertEqual(impact?.model, "claude-sonnet")
        XCTAssertEqual(impact?.shouldWarn, true)
        XCTAssertEqual(impact?.rebuildEUR ?? 0, 0.34875, accuracy: 0.000_001)
        XCTAssertEqual(impact?.extraEURVersusWarm ?? 0, 0.32085, accuracy: 0.000_001)
    }

    func test_repricesSameContextForTargetModel() throws {
        let sonnet = try XCTUnwrap(PromptCacheImpactService.estimate(contextTokens: 80_000, model: "sonnet"))
        let opus = PromptCacheImpactService.repriced(sonnet, for: "opus")
        let haiku = PromptCacheImpactService.repriced(sonnet, for: "haiku")

        XCTAssertEqual(opus.contextTokens, sonnet.contextTokens)
        XCTAssertGreaterThan(opus.rebuildEUR, sonnet.rebuildEUR)
        XCTAssertLessThan(haiku.rebuildEUR, sonnet.rebuildEUR)
    }

    func test_smallOrMissingContextDoesNotWarn() throws {
        let queue = try makeDatabase()
        XCTAssertNil(try queue.read { try PromptCacheImpactService.latest(in: $0, sessionId: "missing") })
        XCTAssertNil(PromptCacheImpactService.estimate(contextTokens: 0, model: "opus"))
        XCTAssertEqual(PromptCacheImpactService.estimate(contextTokens: 29_999, model: "opus")?.shouldWarn, false)
    }
}
