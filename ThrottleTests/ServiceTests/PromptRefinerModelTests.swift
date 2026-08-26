@testable import Throttle
import XCTest

/// The model lives outside the view tree so switching sidebar segments never
/// loses a typed draft. These tests pin that promise and the screen flow.
@MainActor
final class PromptRefinerModelTests: XCTestCase {

    private func freshModel() -> PromptRefinerModel {
        let m = PromptRefinerModel()
        m.reset()
        return m
    }

    func test_beginCompose_movesHomeToComposeAndKeepsTheDraft() {
        let m = freshModel()
        m.draft = "fix scroll"
        m.beginCompose()
        XCTAssertEqual(m.screen, .compose)
        XCTAssertEqual(m.draft, "fix scroll")
    }

    func test_accept_movesToResultAndRecordsHistory() {
        let m = freshModel()
        m.draft = "fix scroll"
        m.screen = .loading
        m.accept(PromptRefinerService.Refinement(
            proposed: "Fix the trackpad scroll in DroppableTerminalView.",
            why: ["named the file"], changed: true, provider: "Apple Intelligence"))
        XCTAssertEqual(m.screen, .result)
        XCTAssertEqual(m.history.count, 1)
        XCTAssertEqual(m.history[0].draft, "fix scroll")
        XCTAssertEqual(m.history[0].proposed, "Fix the trackpad scroll in DroppableTerminalView.")
    }

    func test_appliedScreenKeepsTheResultVisibleInsteadOfDroppingHome() {
        let m = freshModel()
        m.draft = "fix scroll"
        m.accept(PromptRefinerService.Refinement(
            proposed: "Fix the scroll.", why: [], changed: true, provider: "p"))
        m.screen = .applied
        // The proposal survives, so the confirmation sits under the text the
        // user just applied rather than replacing it with the home list.
        XCTAssertEqual(m.proposal?.proposed, "Fix the scroll.")
        XCTAssertEqual(m.screen, .applied)
    }

    func test_fail_keepsTheDraftSoNothingTypedIsLost() {
        let m = freshModel()
        m.draft = "fix scroll"
        m.screen = .loading
        m.fail("No AI provider available.")
        XCTAssertEqual(m.screen, .error("No AI provider available."))
        XCTAssertEqual(m.draft, "fix scroll")
    }

    func test_history_isCappedAndNewestFirst() {
        let m = freshModel()
        for i in 0..<(PromptRefinerModel.historyLimit + 5) {
            m.draft = "draft \(i)"
            m.accept(PromptRefinerService.Refinement(
                proposed: "proposed \(i)", why: [], changed: true, provider: "p"))
        }
        XCTAssertEqual(m.history.count, PromptRefinerModel.historyLimit)
        XCTAssertEqual(m.history.first?.draft, "draft \(PromptRefinerModel.historyLimit + 4)")
    }

    func test_historyTitle_isTheFirstLineTrimmed() {
        let m = freshModel()
        m.draft = "make the scroll work\nand add a test"
        m.accept(PromptRefinerService.Refinement(proposed: "x", why: [], changed: true, provider: "p"))
        XCTAssertEqual(m.history[0].title, "make the scroll work")
    }

    // MARK: - Rationale visibility setting

    func test_rationaleVisibility_missionOnlyIsTheDefaultBehaviour() {
        XCTAssertFalse(RefinerRationale.missionOnly.isVisible(for: .session))
        XCTAssertTrue(RefinerRationale.missionOnly.isVisible(for: .mission))
        XCTAssertTrue(RefinerRationale.missionOnly.isVisible(for: .loop))
    }

    func test_rationaleVisibility_alwaysAndNeverIgnoreTheMode() {
        for mode in RefinerMode.allCases {
            XCTAssertTrue(RefinerRationale.always.isVisible(for: mode))
            XCTAssertFalse(RefinerRationale.never.isVisible(for: mode))
        }
    }

    func test_rationaleVisibility_collapsedStartsHiddenButRemainsReachable() {
        XCTAssertFalse(RefinerRationale.collapsed.isVisible(for: .mission))
        XCTAssertTrue(RefinerRationale.collapsed.isExpandable)
        XCTAssertFalse(RefinerRationale.never.isExpandable)
    }
}
