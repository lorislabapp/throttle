@testable import Throttle
import XCTest

/// The two events Throttle writes about a finished task — `checked` (the
/// verification it ran itself) and `integrated` (the fast-forward it performed)
/// — and what they do to the task itself and to whatever depends on it. Split out
/// of `PlanProjectionTests` (lot F) once that file crossed the 400-line limit.
final class PlanProjectionIntegrationEventsTests: XCTestCase {

    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: Int) -> Date { origin.addingTimeInterval(Double(seconds)) }

    private func task(_ id: String, parent: String? = nil, order: Int = 0,
                      dependsOn: [String] = [], sotaGate: Bool = false) -> PlanTask {
        PlanTask(id: id, parent: parent, order: order, title: id,
                 dependsOn: dependsOn, sotaGate: sotaGate)
    }

    func testCheckedIsAcceptedOnADoneTaskWhoeverWroteIt() {
        let projected = PlanProjection.project(task: task("T1"), events: [
            TaskEvent(seq: 1, timestamp: at(0), author: "codex:a", type: .claimed),
            TaskEvent(seq: 2, timestamp: at(1), author: "codex:a", type: .completed),
            TaskEvent(seq: 3, timestamp: at(2), author: "throttle:app", type: .checked,
                      ref: "abc+def", passed: true)
        ])
        XCTAssertTrue(projected.rejected.isEmpty, "Throttle's own check is not an agent report")
        XCTAssertEqual(projected.lastCheck?.stamp, "abc+def")
        XCTAssertEqual(projected.lastCheck?.passed, true)
        XCTAssertEqual(projected.status, .done, "a check does not move the task")
    }

    func testCheckedIsRefusedBeforeTheTaskIsDone() {
        let projected = PlanProjection.project(task: task("T1"), events: [
            TaskEvent(seq: 1, timestamp: at(0), author: "codex:a", type: .claimed),
            TaskEvent(seq: 2, timestamp: at(1), author: "throttle:app", type: .checked,
                      ref: "abc+def", passed: true)
        ])
        XCTAssertEqual(projected.rejected.first?.reason, .terminal)
        XCTAssertNil(projected.lastCheck)
    }

    func testCandidateIsNotDoneOnTheWorkersWord() {
        let projected = PlanProjection.project(task: task("T1"), events: [
            TaskEvent(seq: 1, timestamp: at(0), author: "codex:a", type: .claimed),
            TaskEvent(seq: 2, timestamp: at(1), author: "codex:a",
                      type: .candidateComplete, summary: "ready")
        ])
        XCTAssertEqual(projected.status, .candidate)
        XCTAssertEqual(projected.pct, 100)
        XCTAssertEqual(projected.summary, "ready")
        XCTAssertNil(projected.owner, "the worker's lease ends with its candidate")
        XCTAssertEqual(projected.runtime, "codex", "the producer remains known for independent review")
    }

    func testOnlyPassingCoordinatorCheckPromotesCandidate() {
        let events = [
            TaskEvent(seq: 1, timestamp: at(0), author: "codex:a", type: .claimed),
            TaskEvent(seq: 2, timestamp: at(1), author: "codex:a", type: .candidateComplete),
            TaskEvent(seq: 3, timestamp: at(2), author: "throttle:app", type: .checked,
                      ref: "abc+def", passed: false),
            TaskEvent(seq: 4, timestamp: at(3), author: "throttle:app", type: .checked,
                      ref: "abc+def", passed: true)
        ]
        let failed = PlanProjection.project(task: task("T1"), events: Array(events.prefix(3)))
        XCTAssertEqual(failed.status, .candidate)
        XCTAssertEqual(failed.lastCheck?.passed, false)
        XCTAssertEqual(PlanProjection.project(task: task("T1"), events: events).status, .done)
    }

    func testGatedCandidateNeedsGreenCheckBeforeIndependentReview() {
        let events = [
            TaskEvent(seq: 1, timestamp: at(0), author: "codex:a", type: .claimed),
            TaskEvent(seq: 2, timestamp: at(1), author: "codex:a", type: .candidateComplete)
        ]
        XCTAssertEqual(PlanProjection.project(task: task("T1", sotaGate: true),
                                               events: events).status, .candidate)
        let checked = events + [
            TaskEvent(seq: 3, timestamp: at(2), author: "throttle:app", type: .checked,
                      ref: "abc+def", passed: true)
        ]
        XCTAssertEqual(PlanProjection.project(task: task("T1", sotaGate: true),
                                               events: checked).status, .review)
    }

    func testIntegratedMovesADoneTaskAndIsItselfTerminal() {
        let projected = PlanProjection.project(task: task("T1"), events: [
            TaskEvent(seq: 1, timestamp: at(0), author: "codex:a", type: .claimed),
            TaskEvent(seq: 2, timestamp: at(1), author: "codex:a", type: .completed),
            TaskEvent(seq: 3, timestamp: at(2), author: "throttle:app", type: .integrated,
                      ref: "deadbeef"),
            TaskEvent(seq: 4, timestamp: at(3), author: "codex:a", type: .progress, pct: 50)
        ])
        XCTAssertEqual(projected.status, .integrated)
        XCTAssertEqual(projected.integratedSHA, "deadbeef")
        XCTAssertEqual(projected.rejected.last?.reason, .terminal,
                       "nothing follows an integration")
    }

    func testIntegratedDependencyDoesNotBlockItsDependent() {
        let plan = Plan(projectId: "p", title: "P", tasks: [
            task("A"),
            task("B", dependsOn: ["A"])
        ])
        var integrated = TaskState()
        integrated.status = .integrated
        let states = PlanProjection.resolve(plan: plan, leafStates: ["A": integrated])
        XCTAssertEqual(states["B"]?.status, .pending,
                       "an integrated dependency is finished, so B is not blocked")
    }

    func testRollupCountsIntegratedChildrenAsFinished() {
        let plan = Plan(projectId: "p", title: "P", tasks: [
            task("phase"),
            task("A", parent: "phase"),
            task("B", parent: "phase")
        ])
        var done = TaskState(); done.status = .done
        var integrated = TaskState(); integrated.status = .integrated
        let states = PlanProjection.resolve(plan: plan, leafStates: ["A": done, "B": integrated])
        XCTAssertEqual(states["phase"]?.status, .done)
    }
}
