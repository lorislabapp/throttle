import Foundation
@testable import Throttle
import XCTest

@MainActor
final class TerminalIdentityPrivacyTests: XCTestCase {
    func testAuthenticationStartedForAnOldTerminalCannotUnlockAfterInvalidation() async {
        let gate = MirrorTestGate<Bool>()
        let state = TerminalLockState(authenticationOverride: { await gate.value() })
        let pending = Task { await state.unlock() }
        await gate.waitUntilEntered()
        state.lock()
        await gate.resume(true)
        let accepted = await pending.value
        XCTAssertFalse(accepted)
        XCTAssertFalse(state.unlocked)
    }
}
