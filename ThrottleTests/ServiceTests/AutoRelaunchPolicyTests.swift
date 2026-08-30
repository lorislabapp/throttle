@testable import Throttle
import XCTest

/// The only automatic session start in the app. What matters is everything that
/// stops it: a ceiling on retries, a ceiling on spend, and never stepping on a
/// task somebody already took.
final class AutoRelaunchPolicyTests: XCTestCase {

    private func state(status: TaskStatus, rejections: Int, owner: String? = nil) -> TaskState {
        var value = TaskState()
        value.status = status
        value.rejectionCount = rejections
        value.owner = owner
        return value
    }

    func testRelaunchesARejectedTaskWithinBudget() {
        let decision = AutoRelaunchPolicy.decide(
            state: state(status: .pending, rejections: 1), attemptsSoFar: 1,
            spendCapEUR: 5, estimatedAgentCostEUR: 1)
        XCTAssertTrue(decision.relaunch)
    }

    func testStopsAtTheRetryCeiling() {
        let decision = AutoRelaunchPolicy.decide(
            state: state(status: .pending, rejections: PlanProjection.maxRejections),
            attemptsSoFar: 3, spendCapEUR: 100, estimatedAgentCostEUR: 1)
        XCTAssertFalse(decision.relaunch)
    }

    /// The spend cap is what replaces the human gesture, so it has to actually bite.
    func testStopsWhenTheNextAttemptWouldPassTheCap() {
        let decision = AutoRelaunchPolicy.decide(
            state: state(status: .pending, rejections: 1), attemptsSoFar: 2,
            spendCapEUR: 2, estimatedAgentCostEUR: 1)
        XCTAssertFalse(decision.relaunch)
        XCTAssertTrue(decision.reason.contains("cap"))
    }

    func testNeverRelaunchesATaskSomeoneHolds() {
        let decision = AutoRelaunchPolicy.decide(
            state: state(status: .pending, rejections: 1, owner: "codex:a"),
            attemptsSoFar: 1, spendCapEUR: 100, estimatedAgentCostEUR: 1)
        XCTAssertFalse(decision.relaunch)
    }

    func testNeverRelaunchesATaskThatWasNeverRejected() {
        let decision = AutoRelaunchPolicy.decide(
            state: state(status: .pending, rejections: 0), attemptsSoFar: 0,
            spendCapEUR: 100, estimatedAgentCostEUR: 1)
        XCTAssertFalse(decision.relaunch)
    }

    /// Without a cost estimate the cap means nothing, so the loop stays shut.
    func testWillNotSpendBlind() {
        let decision = AutoRelaunchPolicy.decide(
            state: state(status: .pending, rejections: 1), attemptsSoFar: 1,
            spendCapEUR: 100, estimatedAgentCostEUR: 0)
        XCTAssertFalse(decision.relaunch)
    }

    func testDoesNotRelaunchAFailedTask() {
        let decision = AutoRelaunchPolicy.decide(
            state: state(status: .failed, rejections: 3), attemptsSoFar: 3,
            spendCapEUR: 100, estimatedAgentCostEUR: 1)
        XCTAssertFalse(decision.relaunch)
    }
}
