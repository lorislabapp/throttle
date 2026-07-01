import XCTest
import GRDB
@testable import Throttle

/// CacheBustAnalyzer: classifies recoverable prompt-cache misses into model-swap vs
/// prefix-churn, and prices them.
final class CacheBustAnalyzerTests: XCTestCase {

    private func makeDatabase() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try Migrations.register(on: db)
        return db
    }

    private func insert(_ db: Database, session: String, ts: Int64, model: String, cacheCreate: Int) throws {
        var ev = UsageEvent(id: nil, sessionId: session, timestamp: ts, model: model,
                            inputTokens: 100, outputTokens: 0, cacheCreate: cacheCreate, cacheRead: 0, serviceTier: nil)
        try ev.insert(db)
    }

    func test_classifiesModelSwapAndPrefixChurn() throws {
        let db = try makeDatabase()
        let base = Int64(Date().timeIntervalSince1970)
        try db.write { db in
            // Prior turn (opus), then a big write same model 60s later → prefix churn.
            try insert(db, session: "s", ts: base, model: "claude-opus-4-6", cacheCreate: 0)
            try insert(db, session: "s", ts: base + 60, model: "claude-opus-4-6", cacheCreate: 50_000)
            // Next turn switches to sonnet 60s later, big write → model swap.
            try insert(db, session: "s", ts: base + 120, model: "claude-sonnet-4-6", cacheCreate: 50_000)
        }
        let report = try db.read { try CacheBustAnalyzer.analyze(in: $0, now: Date(timeIntervalSince1970: Double(base + 200))) }

        let churn = report.causes.first { $0.kind == .prefixChurn }
        let swap = report.causes.first { $0.kind == .modelSwap }
        XCTAssertEqual(churn?.tokens, 50_000)
        XCTAssertEqual(swap?.tokens, 50_000)
        XCTAssertEqual(churn?.events, 1)
        XCTAssertEqual(swap?.events, 1)
        // Opus (rate 5) churn costs more than sonnet (rate 3) swap → dominant = churn.
        XCTAssertEqual(report.dominant?.kind, .prefixChurn)
        XCTAssertGreaterThan(report.totalEUR, 0)
        XCTAssertEqual(report.totalTokens, 100_000)
    }

    func test_excludesSmallWritesAndLongGaps() throws {
        let db = try makeDatabase()
        let base = Int64(Date().timeIntervalSince1970)
        try db.write { db in
            try insert(db, session: "s", ts: base, model: "claude-opus-4-6", cacheCreate: 0)
            try insert(db, session: "s", ts: base + 60, model: "claude-opus-4-6", cacheCreate: 5_000)     // too small
            try insert(db, session: "s", ts: base + 60 + 400, model: "claude-opus-4-6", cacheCreate: 50_000) // gap > 300
        }
        let report = try db.read { try CacheBustAnalyzer.analyze(in: $0) }
        XCTAssertTrue(report.causes.isEmpty, "small writes and long gaps are not recoverable misses")
        XCTAssertEqual(report.totalTokens, 0)
    }

    func test_firstEventOfSessionNeverCounts() throws {
        let db = try makeDatabase()
        let base = Int64(Date().timeIntervalSince1970)
        try db.write { db in
            // A lone big write with no prior turn (gap IS NULL) → not a miss.
            try insert(db, session: "s", ts: base, model: "claude-opus-4-6", cacheCreate: 90_000)
        }
        let report = try db.read { try CacheBustAnalyzer.analyze(in: $0) }
        XCTAssertTrue(report.causes.isEmpty)
    }

    func test_advice_isCauseSpecific() {
        XCTAssertTrue(CacheBustAnalyzer.Kind.modelSwap.advice.lowercased().contains("model"))
        XCTAssertTrue(CacheBustAnalyzer.Kind.prefixChurn.advice.lowercased().contains("prefix"))
    }
}
