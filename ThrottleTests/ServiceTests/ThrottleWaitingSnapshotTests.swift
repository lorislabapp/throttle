@testable import Throttle
import XCTest

final class ThrottleWaitingSnapshotTests: XCTestCase {
    func testQuestionsComeFirstThenDecisionsThenBlockedWork() {
        let snapshot = ThrottleWaitingSnapshot.make(
            questions: [("Aegis", "Keep the old endpoint?")],
            projects: [ThrottleWaitingProject(name: "Throttle", decisions: ["Licence"], blocked: 2),
                       ThrottleWaitingProject(name: "Site", decisions: [], blocked: 0)]
        )
        XCTAssertEqual(snapshot.items.map(\.kind), [.question, .decision, .blocked])
        XCTAssertEqual(snapshot.items.last?.context, "Throttle")
        XCTAssertTrue(snapshot.spokenSummary.contains("Aegis"))
    }

    func testNothingWaitingSaysSo() {
        let site = ThrottleWaitingProject(name: "Site", decisions: [], blocked: 0)
        let snapshot = ThrottleWaitingSnapshot.make(questions: [], projects: [site])
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertEqual(snapshot.spokenSummary, String(localized: "Nothing waits on you."))
    }
}
