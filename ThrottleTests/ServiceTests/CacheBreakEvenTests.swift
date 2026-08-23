@testable import Throttle
import XCTest

/// The break-even number decides whether the user should trim now or leave the
/// session alone, so a wrong verdict costs them real money. The cases that matter
/// are the two ends: a cold cache (trim is free money) and a warm cache with a thin
/// trim (trim is a loss for a long time).
final class CacheBreakEvenTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func lastActivity(minutesAgo: Double) -> Date {
        now.addingTimeInterval(-minutesAgo * 60)
    }

    // MARK: - Cold cache

    func testColdCachePaysImmediately() {
        let v = CacheBreakEven.evaluate(
            prefixTokens: 100_000, trimmableTokens: 20_000,
            lastActivity: lastActivity(minutesAgo: 90), now: now
        )
        XCTAssertEqual(v, CacheBreakEven.Verdict(cacheWasWarm: false, turns: 1))
        XCTAssertTrue(v?.paysImmediately == true)
    }

    func testCacheGoesColdExactlyAtTTL() {
        let atTTL = now.addingTimeInterval(-CacheBreakEven.cacheTTL)
        XCTAssertEqual(
            CacheBreakEven.evaluate(prefixTokens: 50_000, trimmableTokens: 5_000,
                                    lastActivity: atTTL, now: now)?.cacheWasWarm,
            false
        )
        // One second inside the TTL is still warm.
        XCTAssertEqual(
            CacheBreakEven.evaluate(prefixTokens: 50_000, trimmableTokens: 5_000,
                                    lastActivity: atTTL.addingTimeInterval(1), now: now)?.cacheWasWarm,
            true
        )
    }

    // MARK: - Warm cache

    /// A thin trim on a warm cache: rewriting 95k at 1.25× to save 5k of reads per
    /// turn takes a long time to earn back. n* = ⌈(95000·1.25 − 100000·0.10)/(5000·0.10)⌉ + 1
    ///                                        = ⌈108750/500⌉ + 1 = 219.
    func testWarmCacheThinTrimTakesManyTurns() {
        let v = CacheBreakEven.evaluate(
            prefixTokens: 100_000, trimmableTokens: 5_000,
            lastActivity: lastActivity(minutesAgo: 2), now: now
        )
        XCTAssertEqual(v?.cacheWasWarm, true)
        XCTAssertEqual(v?.turns, 219)
        XCTAssertFalse(v?.paysImmediately == true)
    }

    /// Trimming nearly everything while warm still costs one rewrite, but the
    /// residual prefix is tiny so it is earned back almost at once.
    /// n* = ⌈(1000·1.25 − 100000·0.10)/(99000·0.10)⌉ + 1 → penalty is negative → 1.
    func testWarmCacheFatTrimPaysImmediately() {
        let v = CacheBreakEven.evaluate(
            prefixTokens: 100_000, trimmableTokens: 99_000,
            lastActivity: lastActivity(minutesAgo: 2), now: now
        )
        XCTAssertEqual(v, CacheBreakEven.Verdict(cacheWasWarm: true, turns: 1))
    }

    // MARK: - Degenerate inputs return nil rather than a made-up number

    func testNothingToTrimIsNil() {
        XCTAssertNil(CacheBreakEven.evaluate(prefixTokens: 10_000, trimmableTokens: 0,
                                             lastActivity: now, now: now))
    }

    func testEmptyPrefixIsNil() {
        XCTAssertNil(CacheBreakEven.evaluate(prefixTokens: 0, trimmableTokens: 500,
                                             lastActivity: now, now: now))
    }

    func testTrimmingTheEntirePrefixIsNil() {
        XCTAssertNil(CacheBreakEven.evaluate(prefixTokens: 10_000, trimmableTokens: 10_000,
                                             lastActivity: now, now: now))
        // Over-reported trimmable is clamped to the prefix, so it degenerates too.
        XCTAssertNil(CacheBreakEven.evaluate(prefixTokens: 10_000, trimmableTokens: 12_000,
                                             lastActivity: now, now: now))
    }
}
