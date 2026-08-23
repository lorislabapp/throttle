@testable import Throttle
import XCTest

@MainActor
final class TerminalLockStateTests: XCTestCase {
    func testStartsLockedAndRejectsFailedAuthentication() async {
        let state = TerminalLockState(authenticationOverride: { false })

        XCTAssertFalse(state.unlocked)
        let result = await state.unlock()
        XCTAssertFalse(result)
        XCTAssertFalse(state.unlocked)
        XCTAssertNotNil(state.lastError)
    }

    func testUnlockRelocksAfterIdleDeadline() async throws {
        let state = TerminalLockState(
            relockAfterNanoseconds: 10_000_000,
            authenticationOverride: { true }
        )

        let result = await state.unlock()
        XCTAssertTrue(result)
        XCTAssertTrue(state.unlocked)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(state.unlocked)
    }

    /// Timings are deliberately generous. This asserted a 30 ms relock window
    /// with 20 ms sleeps — 10 ms of margin — and passed on this Mac while failing
    /// on the CI runner, where a `Task.sleep(20ms)` under load routinely
    /// overshoots by more than that. A timeout test whose margin is smaller than
    /// the scheduler's jitter is a coin flip, not a check.
    ///
    /// Scaled ×20: a 600 ms window with 400 ms steps leaves 200 ms of slack at
    /// each assertion, and the whole test still runs in about a second. It
    /// remains wall-clock based — the real fix is injecting a clock into
    /// `TerminalLockState` — but the margin is now larger than the noise.
    func testWriteActivityExtendsUnlockWindow() async throws {
        let state = TerminalLockState(
            relockAfterNanoseconds: 600_000_000,
            authenticationOverride: { true }
        )

        let result = await state.unlock()
        XCTAssertTrue(result)
        try await Task.sleep(nanoseconds: 400_000_000)
        state.registerWriteActivity()          // window restarts here
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(state.unlocked, "400 ms into a 600 ms window that just restarted")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(state.unlocked, "800 ms into a 600 ms window")
    }
}
