import Foundation
import SwiftTerm
@testable import Throttle
import XCTest

@MainActor
final class RemoteTerminalPrivacyTests: XCTestCase {
    func testInvalidationRetiresBothBuffersScrollbackAndOldParserState() throws {
        let lock = TerminalLockState(authenticationOverride: { true })
        let coordinator = RemoteTerminalView.Coordinator(lockState: lock)
        let oldView = coordinator.terminalView()
        let oldEngine = oldView.getTerminal()
        oldEngine.resize(cols: 80, rows: 24)
        oldEngine.feed(text: "ACCOUNT_A_NORMAL\r\n" + String(repeating: "history\r\n", count: 100))
        oldEngine.feed(text: "\u{1B}[?1049hACCOUNT_A_ALTERNATE")
        XCTAssertTrue(try contents(oldEngine, kind: .normal).contains("ACCOUNT_A_NORMAL"))
        XCTAssertTrue(try contents(oldEngine, kind: .alt).contains("ACCOUNT_A_ALTERNATE"))
        oldEngine.feed(text: "\u{1B}]0;unfinished-old-title")

        coordinator.invalidateTerminal()
        XCTAssertTrue(oldView.isHidden)
        XCTAssertNil(coordinator.terminal)
        XCTAssertNil(coordinator.cachedView)
        let freshView = coordinator.terminalView()
        let freshEngine = freshView.getTerminal()
        freshEngine.resize(cols: 80, rows: 24)
        XCTAssertFalse(freshView === oldView)
        XCTAssertFalse(freshEngine === oldEngine)
        XCTAssertFalse(try contents(freshEngine, kind: .normal).contains("ACCOUNT_A"))
        XCTAssertFalse(try contents(freshEngine, kind: .alt).contains("ACCOUNT_A"))
        freshEngine.feed(text: "\u{1B}[?1049hACCOUNT_B")
        let visible = try contents(freshEngine, kind: .active)
        XCTAssertFalse(visible.contains("ACCOUNT_A"))
        XCTAssertTrue(visible.contains("ACCOUNT_B"))
        coordinator.invalidateTerminal()
    }

    private func contents(_ terminal: Terminal, kind: Terminal.BufferKind) throws -> String {
        try XCTUnwrap(String(data: terminal.getBufferAsData(kind: kind), encoding: .utf8))
    }
}
