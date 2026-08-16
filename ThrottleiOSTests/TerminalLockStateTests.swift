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

    func testWriteActivityExtendsUnlockWindow() async throws {
        let state = TerminalLockState(
            relockAfterNanoseconds: 30_000_000,
            authenticationOverride: { true }
        )

        let result = await state.unlock()
        XCTAssertTrue(result)
        try await Task.sleep(nanoseconds: 20_000_000)
        state.registerWriteActivity()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(state.unlocked)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(state.unlocked)
    }
}
