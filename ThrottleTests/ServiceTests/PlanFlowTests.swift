@testable import Throttle
import XCTest

final class PlanFlowTests: XCTestCase {
    private let plan = Plan(projectId: "demo", title: "Demo", tasks: [
        PlanTask(id: "phase", order: 0, title: "Phase"),
        PlanTask(id: "T1", parent: "phase", order: 0, title: "Map"),
        PlanTask(id: "T2", parent: "phase", order: 1, title: "List", dependsOn: ["T1"]),
        PlanTask(id: "T3", parent: "phase", order: 2, title: "Ship"),
        PlanTask(id: "T4", parent: "phase", order: 3, title: "Fix")
    ])

    private func state(_ status: TaskStatus, rejections: Int = 0, owner: String? = nil) -> TaskState {
        var state = TaskState()
        state.status = status
        state.rejectionCount = rejections
        state.owner = owner
        return state
    }

    private func stages(_ states: [String: TaskState]) -> [String: PlanFlow.Stage] {
        let overview = ProjectOverview.project(plan: plan, states: states)
        return Dictionary(uniqueKeysWithValues: overview.tasks.map { ($0.id, PlanFlow.stage(of: $0)) })
    }

    func testPendingTaskWithUnfinishedDependencyWaits() {
        let result = stages([:])
        XCTAssertEqual(result["T1"], .toStart)
        XCTAssertEqual(result["T2"], .waiting)
    }

    func testRejectedWorkIsInToFixNotWorking() {
        let result = stages(["T1": state(.running, rejections: 1, owner: "claudeCode:a"),
                             "T3": state(.running, owner: "codex:b"),
                             "T4": state(.failed)])
        XCTAssertEqual(result["T1"], .fixing)
        XCTAssertEqual(result["T3"], .working)
        XCTAssertEqual(result["T4"], .fixing)
    }

    func testFocusPrefersBrokenWorkOverNewWork() {
        let overview = ProjectOverview.project(plan: plan, states: ["T4": state(.failed)])
        XCTAssertEqual(PlanFlow.focus(overview)?.item.id, "T4")
        XCTAssertEqual(PlanFlow.focus(overview)?.stage, .fixing)
    }

    func testHealthSaysUnknownWithoutTestRuns() {
        let overview = ProjectOverview.project(plan: plan, states: [:])
        let proofs = PlanFlow.health(overview).first { $0.kind == .proofsGreen }
        XCTAssertEqual(proofs?.verdict, .unknown)
    }

    func testTotalsCountEveryLeafOnce() {
        let overview = ProjectOverview.project(plan: plan, states: ["T3": state(.done)])
        let totals = PlanFlow.totals([overview])
        XCTAssertEqual(totals.values.reduce(0, +), 4)
        XCTAssertEqual(totals[.ready], 1)
    }
}
