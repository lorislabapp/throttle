import XCTest
@testable import Throttle

/// Poll-cadence policy: failure backoff, the new capped-window "honor the reset"
/// backoff (don't hammer claude.ai into the wall while a window is at 100%), and
/// the normal high/low cadence.
final class ExactModePollPolicyTests: XCTestCase {

    private func snap(five: Int, fiveReset: Date?, seven: Int = 0, sonnet: Int = 0, at: Date) -> ExactSnapshot {
        ExactSnapshot(
            fiveHour: .init(utilization: five, resetsAt: fiveReset),
            sevenDay: .init(utilization: seven, resetsAt: nil),
            sevenDaySonnet: .init(utilization: sonnet, resetsAt: nil),
            fetchedAt: at)
    }

    func test_failure_exponentialBackoff() {
        XCTAssertEqual(ExactModeService.pollPolicy(now: Date(), snapshot: nil, consecutiveFailures: 1), .seconds(30))
        XCTAssertEqual(ExactModeService.pollPolicy(now: Date(), snapshot: nil, consecutiveFailures: 3), .seconds(120))
        XCTAssertEqual(ExactModeService.pollPolicy(now: Date(), snapshot: nil, consecutiveFailures: 99), .seconds(15 * 60))
    }

    func test_noFreshSnapshot_fiveMinutes() {
        XCTAssertEqual(ExactModeService.pollPolicy(now: Date(), snapshot: nil, consecutiveFailures: 0), .seconds(5 * 60))
    }

    // Anti-flap: while a FRESH snapshot is on the meter, a failure retries fast (60 s)
    // to refresh before the 10-min freshness window expires — not a long backoff that
    // would let the number blank then reappear. Backoff resumes once it's stale.
    func test_failure_withFreshSnapshot_retriesFastNotBackoff() {
        let now = Date()
        let fresh = snap(five: 40, fiveReset: nil, at: now)                       // fetched now → fresh
        XCTAssertEqual(ExactModeService.pollPolicy(now: now, snapshot: fresh, consecutiveFailures: 1), .seconds(60))
        XCTAssertEqual(ExactModeService.pollPolicy(now: now, snapshot: fresh, consecutiveFailures: 6), .seconds(60))
        let stale = snap(five: 40, fiveReset: nil, at: now.addingTimeInterval(-11 * 60))  // >10 min → stale
        XCTAssertEqual(ExactModeService.pollPolicy(now: now, snapshot: stale, consecutiveFailures: 3), .seconds(120))
    }

    func test_cappedWindow_backsOffUntilReset() {
        let now = Date()
        let s = snap(five: 100, fiveReset: now.addingTimeInterval(8 * 60), at: now)
        XCTAssertEqual(ExactModeService.pollPolicy(now: now, snapshot: s, consecutiveFailures: 0), .seconds(8 * 60 + 5))
    }

    func test_cappedWindow_cappedAt15min() {
        let now = Date()
        let s = snap(five: 100, fiveReset: now.addingTimeInterval(3 * 3600), at: now)
        XCTAssertEqual(ExactModeService.pollPolicy(now: now, snapshot: s, consecutiveFailures: 0), .seconds(15 * 60))
    }

    func test_cappedButResetInPast_ignored() {
        let now = Date()
        let s = snap(five: 100, fiveReset: now.addingTimeInterval(-60), at: now)   // stale reset → not a backoff
        XCTAssertEqual(ExactModeService.pollPolicy(now: now, snapshot: s, consecutiveFailures: 0), .seconds(60)) // 100% ≥80 → 60s
    }

    func test_highNotCapped_60s() {
        let now = Date()
        let s = snap(five: 85, fiveReset: now.addingTimeInterval(3600), at: now)
        XCTAssertEqual(ExactModeService.pollPolicy(now: now, snapshot: s, consecutiveFailures: 0), .seconds(60))
    }

    func test_low_5min() {
        let now = Date()
        let s = snap(five: 20, fiveReset: nil, at: now)
        XCTAssertEqual(ExactModeService.pollPolicy(now: now, snapshot: s, consecutiveFailures: 0), .seconds(5 * 60))
    }
}
