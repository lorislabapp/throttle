@testable import Throttle
import XCTest

/// The projection is where every claim about a task's state is decided, so these
/// tests are the spec. The cases that matter are the adversarial ones: two agents
/// racing for the same task, an agent reporting on work it does not own, and a log
/// someone edited behind Throttle's back.
final class PlanProjectionTests: XCTestCase {

    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: Int) -> Date { origin.addingTimeInterval(Double(seconds)) }

    private func task(_ id: String, parent: String? = nil, order: Int = 0,
                      dependsOn: [String] = [], sotaGate: Bool = false) -> PlanTask {
        PlanTask(id: id, parent: parent, order: order, title: id,
                 dependsOn: dependsOn, sotaGate: sotaGate)
    }

    // MARK: - Single task lifecycle

    func testNoEventsIsPending() {
        let projected = PlanProjection.project(task: task("T1"), events: [])
        XCTAssertEqual(projected.status, .pending)
        XCTAssertEqual(projected.pct, 0)
        XCTAssertNil(projected.owner)
    }

    func testClaimSetsOwnerAndRuntime() {
        let projected = PlanProjection.project(task: task("T1"), events: [
            TaskEvent(seq: 1, timestamp: at(0), author: "codex:sess_ab", type: .claimed, missionID: "M1")
        ])
        XCTAssertEqual(projected.status, .claimed)
        XCTAssertEqual(projected.owner, "codex:sess_ab")
        XCTAssertEqual(projected.runtime, "codex")
        XCTAssertEqual(projected.missionID, "M1")
        XCTAssertEqual(projected.startedAt, at(0))
    }

    func testProgressMovesToRunning() {
        let projected = PlanProjection.project(task: task("T1"), events: [
            TaskEvent(seq: 1, timestamp: at(0), author: "codex:a", type: .claimed),
            TaskEvent(seq: 2, timestamp: at(1), author: "codex:a", type: .progress, pct: 40)
        ])
        XCTAssertEqual(projected.status, .running)
        XCTAssertEqual(projected.pct, 40)
    }

    func testCompletedWithoutGateIsDone() {
        let projected = PlanProjection.project(task: task("T1"), events: [
            TaskEvent(seq: 1, timestamp: at(0), author: "codex:a", type: .claimed),
            TaskEvent(seq: 2, timestamp: at(1), author: "codex:a", type: .completed, summary: "ok")
        ])
        XCTAssertEqual(projected.status, .done)
        XCTAssertEqual(projected.pct, 100)
        XCTAssertEqual(projected.summary, "ok")
    }

    /// A gated task is never done on the agent's own say-so — it parks in review
    /// until lot E's counter-analysis runs.
    func testCompletedWithGateParksInReview() {
        let projected = PlanProjection.project(task: task("T1", sotaGate: true), events: [
            TaskEvent(seq: 1, timestamp: at(0), author: "codex:a", type: .claimed),
            TaskEvent(seq: 2, timestamp: at(1), author: "codex:a", type: .completed)
        ])
        XCTAssertEqual(projected.status, .review)
        XCTAssertEqual(projected.pct, 100)
    }

    func testFailedIsTerminal() {
        let projected = PlanProjection.project(task: task("T1"), events: [
            TaskEvent(seq: 1, timestamp: at(0), author: "codex:a", type: .claimed),
            TaskEvent(seq: 2, timestamp: at(1), author: "codex:a", type: .failed, reason: "build broke")
        ])
        XCTAssertEqual(projected.status, .failed)
    }

    func testBlockedThenUnblocked() {
        let events = [
            TaskEvent(seq: 1, timestamp: at(0), author: "codex:a", type: .claimed),
            TaskEvent(seq: 2, timestamp: at(1), author: "codex:a", type: .blocked, reason: "needs key"),
            TaskEvent(seq: 3, timestamp: at(2), author: "codex:a", type: .unblocked)
        ]
        let blocked = PlanProjection.project(task: task("T1"), events: Array(events.prefix(2)))
        XCTAssertEqual(blocked.status, .blocked)
        XCTAssertEqual(blocked.blockedReason, "needs key")

        let unblocked = PlanProjection.project(task: task("T1"), events: events)
        XCTAssertEqual(unblocked.status, .running)
        XCTAssertNil(unblocked.blockedReason)
    }

    func testEvidenceAccumulates() {
        let projected = PlanProjection.project(task: task("T1"), events: [
            TaskEvent(seq: 1, timestamp: at(0), author: "codex:a", type: .claimed),
            TaskEvent(seq: 2, timestamp: at(1), author: "codex:a", type: .evidence, kind: "commit", ref: "a3f"),
            TaskEvent(seq: 3, timestamp: at(2), author: "codex:a", type: .evidence, kind: "test", ref: "42 passed")
        ])
        XCTAssertEqual(projected.evidence.count, 2)
        XCTAssertEqual(projected.evidence.first?.ref, "a3f")
    }

    // MARK: - Ownership races

    /// Two agents reach for the same task. The lower seq wins and the loser is
    /// recorded, not silently dropped.
    func testSecondClaimIsRejected() {
        let projected = PlanProjection.project(task: task("T1"), events: [
            TaskEvent(seq: 1, timestamp: at(0), author: "codex:a", type: .claimed),
            TaskEvent(seq: 2, timestamp: at(1), author: "claude:b", type: .claimed)
        ])
        XCTAssertEqual(projected.owner, "codex:a")
        XCTAssertEqual(projected.rejected.count, 1)
        XCTAssertEqual(projected.rejected.first?.reason, .alreadyOwned)
        XCTAssertEqual(projected.rejected.first?.author, "claude:b")
    }

    /// File order is not authority — seq is. A claim appended later but numbered
    /// first still wins.
    func testLowestSeqWinsRegardlessOfFileOrder() {
        let projected = PlanProjection.project(task: task("T1"), events: [
            TaskEvent(seq: 2, timestamp: at(1), author: "claude:b", type: .claimed),
            TaskEvent(seq: 1, timestamp: at(0), author: "codex:a", type: .claimed)
        ])
        XCTAssertEqual(projected.owner, "codex:a")
    }

    func testNonOwnerProgressIsRejected() {
        let projected = PlanProjection.project(task: task("T1"), events: [
            TaskEvent(seq: 1, timestamp: at(0), author: "codex:a", type: .claimed),
            TaskEvent(seq: 2, timestamp: at(1), author: "claude:b", type: .progress, pct: 90)
        ])
        XCTAssertEqual(projected.pct, 0)
        XCTAssertEqual(projected.rejected.first?.reason, .notOwner)
    }

    func testReleaseFreesTheTaskAndKeepsProgress() {
        let events = [
            TaskEvent(seq: 1, timestamp: at(0), author: "codex:a", type: .claimed),
            TaskEvent(seq: 2, timestamp: at(1), author: "codex:a", type: .progress, pct: 60),
            TaskEvent(seq: 3, timestamp: at(2), author: "codex:a", type: .released)
        ]
        let released = PlanProjection.project(task: task("T1"), events: events)
        XCTAssertNil(released.owner)
        XCTAssertEqual(released.status, .pending)
        XCTAssertEqual(released.pct, 60, "progress already made is a fact, not a lease")

        let reclaimed = PlanProjection.project(task: task("T1"), events: events + [
            TaskEvent(seq: 4, timestamp: at(3), author: "claude:b", type: .claimed)
        ])
        XCTAssertEqual(reclaimed.owner, "claude:b")
        XCTAssertTrue(reclaimed.rejected.isEmpty)
    }

    func testDuplicateSeqIsRejected() {
        let projected = PlanProjection.project(task: task("T1"), events: [
            TaskEvent(seq: 1, timestamp: at(0), author: "codex:a", type: .claimed),
            TaskEvent(seq: 2, timestamp: at(1), author: "codex:a", type: .progress, pct: 30),
            TaskEvent(seq: 2, timestamp: at(2), author: "codex:a", type: .progress, pct: 80)
        ])
        XCTAssertEqual(projected.pct, 30)
        XCTAssertEqual(projected.rejected.first?.reason, .outOfOrder)
    }

    func testEventsAfterTerminalAreRejected() {
        let projected = PlanProjection.project(task: task("T1"), events: [
            TaskEvent(seq: 1, timestamp: at(0), author: "codex:a", type: .claimed),
            TaskEvent(seq: 2, timestamp: at(1), author: "codex:a", type: .completed),
            TaskEvent(seq: 3, timestamp: at(2), author: "codex:a", type: .progress, pct: 10)
        ])
        XCTAssertEqual(projected.status, .done)
        XCTAssertEqual(projected.rejected.first?.reason, .terminal)
    }

    func testBrokenChainIsCarriedIntoTheState() {
        let projected = PlanProjection.project(task: task("T1"), events: [
            TaskEvent(seq: 1, timestamp: at(0), author: "codex:a", type: .claimed)
        ], chainValid: false)
        XCTAssertFalse(projected.chainValid)
        XCTAssertEqual(projected.status, .claimed, "a broken chain is a warning, not a reset")
    }

    // MARK: - Plan-level resolve

    private var twoPhasePlan: Plan {
        Plan(projectId: "p", title: "P", tasks: [
            task("P1", order: 0),
            task("T1.1", parent: "P1", order: 0),
            task("T1.2", parent: "P1", order: 1),
            task("P2", order: 1),
            task("T2.1", parent: "P2", order: 0, dependsOn: ["T1.2"])
        ])
    }

    func testDependencyBlocksAnUnstartedLeaf() {
        let states = PlanProjection.resolve(plan: twoPhasePlan, leafStates: [:])
        XCTAssertEqual(states["T2.1"]?.status, .blocked)
        XCTAssertEqual(states["T2.1"]?.blockedReason, "T1.2")
        XCTAssertEqual(states["T1.1"]?.status, .pending)
    }

    func testDependencySatisfiedUnblocks() {
        var done = TaskState()
        done.status = .done
        done.pct = 100
        let states = PlanProjection.resolve(plan: twoPhasePlan, leafStates: ["T1.2": done])
        XCTAssertEqual(states["T2.1"]?.status, .pending)
    }

    /// A dependency must not override an agent that is already working — that
    /// would let a stale plan edit yank a running task out from under it.
    func testDependencyDoesNotOverrideRunning() {
        var running = TaskState()
        running.status = .running
        running.owner = "codex:a"
        let states = PlanProjection.resolve(plan: twoPhasePlan, leafStates: ["T2.1": running])
        XCTAssertEqual(states["T2.1"]?.status, .running)
    }

    func testParentRollsUpPercentAndStatus() {
        var half = TaskState()
        half.status = .running
        half.pct = 50
        var done = TaskState()
        done.status = .done
        done.pct = 100

        let states = PlanProjection.resolve(plan: twoPhasePlan,
                                            leafStates: ["T1.1": done, "T1.2": half])
        XCTAssertEqual(states["P1"]?.pct, 75)
        XCTAssertEqual(states["P1"]?.status, .running)
    }

    func testParentIsDoneOnlyWhenEveryLeafIsDone() {
        var done = TaskState()
        done.status = .done
        done.pct = 100
        let partial = PlanProjection.resolve(plan: twoPhasePlan, leafStates: ["T1.1": done])
        XCTAssertNotEqual(partial["P1"]?.status, .done)

        let full = PlanProjection.resolve(plan: twoPhasePlan,
                                          leafStates: ["T1.1": done, "T1.2": done])
        XCTAssertEqual(full["P1"]?.status, .done)
        XCTAssertEqual(full["P1"]?.pct, 100)
    }

    func testFailedLeafSurfacesOnTheParent() {
        var failed = TaskState()
        failed.status = .failed
        let states = PlanProjection.resolve(plan: twoPhasePlan, leafStates: ["T1.1": failed])
        XCTAssertEqual(states["P1"]?.status, .failed)
    }
}
