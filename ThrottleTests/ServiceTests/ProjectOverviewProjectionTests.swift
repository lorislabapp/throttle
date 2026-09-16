@testable import Throttle
import XCTest

final class ProjectOverviewProjectionTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    private let plan = Plan(projectId: "demo", title: "Demo", tasks: [
        PlanTask(id: "phase", order: 0, title: "Phase"),
        PlanTask(id: "T1", parent: "phase", order: 0, title: "Model"),
        PlanTask(id: "T2", parent: "phase", order: 1, title: "Inspector"),
        PlanTask(id: "T3", parent: "phase", order: 2, title: "Costs"),
        PlanTask(id: "T4", parent: "phase", order: 3, title: "Migration"),
        PlanTask(id: "D1", parent: "phase", order: 4, title: "Licence", kind: .decision),
        PlanTask(id: "D2", parent: "phase", order: 5, title: "Settled", kind: .decision)
    ])

    private func state(_ status: TaskStatus, pct: Int = 0, check: TaskCheck? = nil,
                       chainValid: Bool = true) -> TaskState {
        var state = TaskState()
        state.status = status
        state.pct = pct
        state.lastCheck = check
        state.chainValid = chainValid
        return state
    }

    func testProgressCountsOnlyIntegratedAndVerifiedTasks() {
        let overview = ProjectOverview.project(plan: plan, states: [
            "phase": state(.running, pct: 90),
            "T1": state(.integrated), "T2": state(.done), "T3": state(.candidate, pct: 100),
            "T4": state(.blocked), "D2": state(.done)
        ])
        XCTAssertEqual(overview.progress.total, 6, "the phase is a parent, not a unit of work")
        XCTAssertEqual(overview.progress.proven, 3)
        XCTAssertEqual(overview.progress.count(.candidate), 1,
                       "a candidate at 100 % declared is still not verified")
        XCTAssertEqual(overview.progress.count(.pending), 1)
        XCTAssertEqual(overview.declaredPct, 90, "the self-reported figure is kept apart, not merged in")
    }

    func testOnlyUnsettledDecisionsWait() {
        let overview = ProjectOverview.project(plan: plan, states: ["D2": state(.done)])
        XCTAssertEqual(overview.decisions.map(\.id), ["D1"])
    }

    func testChangesKeepOnlyTrustMovingEventsNewestFirst() {
        let events: [String: [TaskEvent]] = [
            "T1": [TaskEvent(seq: 1, timestamp: epoch, author: "claude:a", type: .claimed),
                   TaskEvent(seq: 2, timestamp: epoch.addingTimeInterval(60), author: "throttle", type: .integrated)],
            "T4": [TaskEvent(seq: 1, timestamp: epoch.addingTimeInterval(120), author: "claude:b",
                             type: .blocked, reason: "conflict with base")]
        ]
        let overview = ProjectOverview.project(plan: plan, states: [:], events: events)
        XCTAssertEqual(overview.changes.map(\.event.type), [.blocked, .integrated])
        XCTAssertEqual(overview.changes.first?.taskTitle, "Migration")
    }

    func testEvidenceReportsOutcomesAndABrokenChain() {
        let passed = TaskCheck(passed: true, stamp: "a", ranAt: epoch)
        let failed = TaskCheck(passed: false, stamp: "b", ranAt: epoch.addingTimeInterval(10))
        let overview = ProjectOverview.project(plan: plan, states: [
            "T1": state(.integrated, check: passed),
            "T2": state(.failed, check: failed, chainValid: false)
        ])
        XCTAssertEqual(overview.evidence.count(.passed), 1)
        XCTAssertEqual(overview.evidence.count(.failed), 1)
        XCTAssertEqual(overview.evidence.proofs.first?.taskID, "T2", "newest proof first")
        XCTAssertFalse(overview.evidence.chainValid)
    }

    func testCostsNeverInventAFigure() {
        let none = ProjectCostReadout.make(monthEstimateEUR: nil, ledger: nil) { "\($0)" }
        XCTAssertEqual(none.subscriptionQuota, .unmeasured)
        XCTAssertEqual(none.apiInvoice, .unmeasured)
        XCTAssertEqual(none.internalEstimate, .unmeasured)
        XCTAssertEqual(none.reserve, .unmeasured)

        let ledger = BudgetAdmissionLedger(
            periodStartsAt: epoch, periodEndsAt: epoch.addingTimeInterval(86_400),
            capacities: [BudgetCapacity(resource: .costMinorUnits, total: 2_500,
                                        protectedForVerification: 600, protectedForRelease: 0)]
        )
        let some = ProjectCostReadout.make(monthEstimateEUR: 3.1, ledger: ledger) { String(format: "%.2f", $0) }
        XCTAssertEqual(some.internalEstimate, .estimated("3.10"), "a local calculation is never shown as known")
        XCTAssertEqual(some.reserve, .known("25.00"))
        XCTAssertEqual(some.protectedForVerification, "6.00")
    }
}
