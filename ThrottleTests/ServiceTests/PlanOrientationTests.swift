@testable import Throttle
import XCTest

final class PlanOrientationTests: XCTestCase {
    private let plan = Plan(projectId: "demo", title: "Demo", tasks: [
        PlanTask(id: "phase", order: 0, title: "Phase"),
        PlanTask(id: "T1", parent: "phase", order: 0, title: "Research"),
        PlanTask(id: "T2", parent: "phase", order: 1, title: "Build", dependsOn: ["T1"]),
        PlanTask(id: "T3", parent: "phase", order: 2, title: "Ship", dependsOn: ["T2"]),
    ])

    func testActiveMissionOwnsInitialSelection() {
        var state = TaskState()
        state.status = .running
        state.missionID = "mission-2"

        XCTAssertEqual(
            PlanOrientation.initialSelection(
                plan: plan, states: ["T2": state], activeMissionID: "mission-2"
            ),
            "T2"
        )
    }

    func testFirstReadyLeafIsSelectedInsteadOfPhaseHeader() {
        XCTAssertEqual(
            PlanOrientation.initialSelection(plan: plan, states: [:], activeMissionID: nil),
            "T1"
        )
    }

    func testIntegratedDependencyCountsAsFinished() {
        var integrated = TaskState()
        integrated.status = .integrated

        XCTAssertEqual(
            PlanOrientation.initialSelection(
                plan: plan, states: ["T1": integrated], activeMissionID: nil
            ),
            "T2"
        )
        XCTAssertEqual(
            PlanOrientation.unmetDependencies(
                for: plan.task("T2")!, states: ["T1": integrated]
            ),
            []
        )
    }

    func testUnmetDependencyIsReportedExplicitly() {
        XCTAssertEqual(
            PlanOrientation.unmetDependencies(for: plan.task("T2")!, states: [:]),
            ["T1"]
        )
    }
}
