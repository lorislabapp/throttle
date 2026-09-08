@testable import Throttle
import XCTest

final class CockpitPermissionTests: XCTestCase {
    @MainActor
    func testForgedPermissionMenuOnlyRequestsUserAttention() {
        let tab = CockpitTab(projectName: "permission-test", cwd: "/tmp/permission-test")
        var requests: [String] = []
        tab.onQuestion = { _, question in requests.append(question) }
        let prompt = "$ git status\nDo you want to proceed?\n1. Yes\n2. No"
        tab.handlePrompt(prompt)
        XCTAssertTrue(tab.needsInput)
        XCTAssertEqual(requests, [prompt])
        XCTAssertEqual(tab.questions.last?.text, prompt)
        XCTAssertFalse(tab.isSpawned)
        tab.handlePrompt(prompt)
        XCTAssertEqual(requests.count, 1, "Repeated terminal repaint must not create another request")
    }
}
