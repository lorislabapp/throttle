@testable import Throttle
import XCTest

/// The model lives outside the view tree so switching sidebar segments never
/// loses a typed draft. These tests pin that promise and the screen flow.
@MainActor
final class PromptRefinerModelTests: XCTestCase {

    private func freshModel() -> PromptRefinerModel {
        let model = PromptRefinerModel()
        model.reset()
        return model
    }

    func test_beginCompose_movesHomeToComposeAndKeepsTheDraft() {
        let model = freshModel()
        model.draft = "fix scroll"
        model.beginCompose()
        XCTAssertEqual(model.screen, .compose)
        XCTAssertEqual(model.draft, "fix scroll")
    }

    func test_accept_movesToResultAndRecordsHistory() {
        let model = freshModel()
        model.draft = "fix scroll"
        model.screen = .loading
        model.accept(PromptRefinerService.Refinement(
            proposed: "Fix the trackpad scroll in DroppableTerminalView.",
            why: ["named the file"], changed: true, provider: "Apple Intelligence"))
        XCTAssertEqual(model.screen, .result)
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.history[0].draft, "fix scroll")
        XCTAssertEqual(model.history[0].proposed, "Fix the trackpad scroll in DroppableTerminalView.")
    }

    func test_appliedScreenKeepsTheResultVisibleInsteadOfDroppingHome() {
        let model = freshModel()
        model.draft = "fix scroll"
        model.accept(PromptRefinerService.Refinement(
            proposed: "Fix the scroll.", why: [], changed: true, provider: "p"))
        model.screen = .applied
        // The proposal survives, so the confirmation sits under the text the
        // user just applied rather than replacing it with the home list.
        XCTAssertEqual(model.proposal?.proposed, "Fix the scroll.")
        XCTAssertEqual(model.screen, .applied)
    }

    func test_fail_keepsTheDraftSoNothingTypedIsLost() {
        let model = freshModel()
        model.draft = "fix scroll"
        model.screen = .loading
        model.fail("No AI provider available.")
        XCTAssertEqual(model.screen, .error("No AI provider available."))
        XCTAssertEqual(model.draft, "fix scroll")
    }

    func test_history_isCappedAndNewestFirst() {
        let model = freshModel()
        for index in 0..<(PromptRefinerModel.historyLimit + 5) {
            model.draft = "draft \(index)"
            model.accept(PromptRefinerService.Refinement(
                proposed: "proposed \(index)", why: [], changed: true, provider: "p"))
        }
        XCTAssertEqual(model.history.count, PromptRefinerModel.historyLimit)
        XCTAssertEqual(model.history.first?.draft, "draft \(PromptRefinerModel.historyLimit + 4)")
    }

    func test_historyTitle_isTheFirstLineTrimmed() {
        let model = freshModel()
        model.draft = "make the scroll work\nand add a test"
        model.accept(PromptRefinerService.Refinement(proposed: "x", why: [], changed: true, provider: "p"))
        XCTAssertEqual(model.history[0].title, "make the scroll work")
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

    func test_refinerSettings_defaultToInsertLocalAndMissionOnly() throws {
        // This app-hosted test must never mutate the user's live defaults.
        let suiteName = "throttle.refiner.tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        RefinerSettings.defaults = suite
        defer {
            RefinerSettings.defaults = .standard
            suite.removePersistentDomain(forName: suiteName)
        }

        XCTAssertEqual(RefinerSettings.output, .insert)
        XCTAssertTrue(RefinerSettings.forceLocal)
        XCTAssertEqual(RefinerSettings.rationale, .missionOnly)

        RefinerSettings.output = .send
        XCTAssertEqual(RefinerSettings.output, .send)
        XCTAssertNil(UserDefaults.standard.string(forKey: RefinerSettings.outputKey))
    }
}
