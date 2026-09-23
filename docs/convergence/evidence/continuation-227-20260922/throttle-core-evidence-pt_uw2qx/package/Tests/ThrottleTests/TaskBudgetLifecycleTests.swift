@testable import Throttle
import XCTest

final class TaskBudgetLifecycleTests: XCTestCase {
    private var root = URL(fileURLWithPath: "/")
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-budget-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try PlanStore(projectRoot: root).bootstrap(Plan(
            projectId: "budget-lifecycle",
            title: "Budget lifecycle",
            tasks: [task()]
        ))
        try BudgetAdmissionStore(projectRoot: root).bootstrap(
            capacities: [BudgetCapacity(
                resource: .frontierTokens,
                total: 100,
                protectedForVerification: 0,
                protectedForRelease: 0
            )],
            periodStartsAt: now,
            periodEndsAt: now.addingTimeInterval(10_000)
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCandidateSettlesTheLocalHoldAsAnExplicitUpperBound() throws {
        let reservation = try claimWithReservation()

        let response = PlanMCPTools.eventText(.init(
            project: root.path,
            taskID: "T1",
            author: "codex:worker",
            type: "candidate_complete",
            pct: nil,
            note: nil,
            kind: nil,
            ref: nil,
            reason: nil,
            summary: "Candidate"
        ))

        XCTAssertTrue(response.contains("candidate"), response)
        let settled = try XCTUnwrap(
            BudgetAdmissionStore(projectRoot: root).snapshot(now: now)
                .reservations.first(where: { $0.id == reservation.id })
        )
        XCTAssertEqual(settled.state, .settled)
        XCTAssertEqual(settled.settlementFidelity, .reservedUpperBound)
        XCTAssertNil(settled.settlementEvidenceRef)
    }

    func testBrokenBudgetLedgerRefusesTheTerminalEvent() throws {
        _ = try claimWithReservation()
        try Data("not-json".utf8).write(
            to: root.appendingPathComponent(".throttle/budget/ledger.json")
        )

        let response = PlanMCPTools.eventText(.init(
            project: root.path,
            taskID: "T1",
            author: "codex:worker",
            type: "failed",
            pct: nil,
            note: nil,
            kind: nil,
            ref: nil,
            reason: "worker stopped",
            summary: nil
        ))

        XCTAssertTrue(response.contains("budget hold could not be reconciled"), response)
        XCTAssertEqual(try PlanStore(projectRoot: root).state(for: "T1").status, .claimed)
    }

    private func claimWithReservation() throws -> BudgetReservation {
        let admission = try XCTUnwrap(TaskBudgetAdmission.reserveIfConfigured(
            task: task(),
            missionID: UUID(),
            projectRoot: root,
            now: now
        ))
        try PlanStore(projectRoot: root).append(TaskEvent(
            seq: 0,
            timestamp: now,
            author: "codex:worker",
            type: .claimed,
            workContractDigest: task().workContract?.digest,
            budgetReservationID: admission.reservation.id,
            budgetLedgerRevision: admission.ledgerRevision
        ), to: "T1")
        return admission.reservation
    }

    private func task() -> PlanTask {
        PlanTask(
            id: "T1",
            title: "Bounded work",
            workContract: WorkflowWorkContract(
                revision: 1,
                objective: "Complete one bounded task.",
                approvedProductReference: "decision:budget-lifecycle",
                requirements: [WorkflowRequirement(
                    id: "R1",
                    statement: "Keep the reservation lifecycle honest.",
                    acceptanceCriteria: ["Terminal events reconcile the local hold."]
                )],
                allowedChangePaths: ["Throttle/"],
                mustPreserve: ["Budget evidence"],
                exclusions: [],
                platforms: [.macOS],
                baseRevision: String(repeating: "a", count: 40),
                inputs: [],
                permissionRequirements: [],
                budget: WorkflowBudgetContract(tokenLimit: WorkflowBudgetAmount(
                    knowledge: .exact,
                    value: 25,
                    unit: "tokens"
                ))
            )
        )
    }
}
