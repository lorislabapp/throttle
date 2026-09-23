@testable import Throttle
import XCTest

final class TaskBudgetAdmissionTests: XCTestCase {
    private var root = URL(fileURLWithPath: "/")
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-budget-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testMissingLedgerIsExplicitlyUnconfiguredAndDoesNotInventCapacity() throws {
        let decision = try TaskBudgetAdmission.reserveIfConfigured(
            task: task(budget: exactBudget(tokens: 10)),
            missionID: UUID(),
            projectRoot: root,
            now: now
        )
        XCTAssertNil(decision)
    }

    func testConfiguredResourceRequiresAnExactWorkContractAmount() throws {
        try bootstrap(total: 100)
        XCTAssertThrowsError(try TaskBudgetAdmission.reserveIfConfigured(
            task: task(budget: WorkflowBudgetContract()),
            missionID: UUID(),
            projectRoot: root,
            now: now
        )) { error in
            XCTAssertEqual(error as? BudgetAdmissionError, .unknownBudget(.frontierTokens))
        }
    }

    func testExactContractCreatesPurposeBoundReservationWithLocalOnlyEnforcement() throws {
        try bootstrap(total: 100)
        let decision = try XCTUnwrap(TaskBudgetAdmission.reserveIfConfigured(
            task: task(budget: exactBudget(tokens: 40, purpose: .verification)),
            missionID: UUID(),
            projectRoot: root,
            now: now
        ))

        XCTAssertEqual(decision.reservation.request.purpose, .verification)
        XCTAssertEqual(
            decision.reservation.request.amounts,
            [BudgetAmount(resource: .frontierTokens, value: 40)]
        )
        XCTAssertEqual(decision.externalEnforcement, .unavailable)
    }

    func testUnitMismatchRefusesBeforeReservation() throws {
        try bootstrap(total: 100)
        var budget = exactBudget(tokens: 40)
        budget.tokenLimit.unit = "USD"

        XCTAssertThrowsError(try TaskBudgetAdmission.reserveIfConfigured(
            task: task(budget: budget),
            missionID: UUID(),
            projectRoot: root,
            now: now
        )) { error in
            XCTAssertEqual(
                error as? BudgetAdmissionError,
                .unsupportedUnit(.frontierTokens, "USD")
            )
        }
    }

    func testCompletionKeepsAnExplicitUpperBoundUntilMeasuredUsageArrives() throws {
        try bootstrap(total: 100)
        let decision = try XCTUnwrap(TaskBudgetAdmission.reserveIfConfigured(
            task: task(budget: exactBudget(tokens: 40)),
            missionID: UUID(),
            projectRoot: root,
            now: now
        ))
        try TaskBudgetAdmission.settleUpperBound(
            reservationID: decision.reservation.id,
            projectRoot: root,
            now: now.addingTimeInterval(5)
        )

        let reservation = try XCTUnwrap(
            BudgetAdmissionStore(projectRoot: root).snapshot(now: now.addingTimeInterval(6))
                .reservations.first
        )
        XCTAssertEqual(reservation.state, .settled)
        XCTAssertEqual(reservation.settlementFidelity, .reservedUpperBound)
        XCTAssertEqual(reservation.countedAmount(for: .frontierTokens), 40)
    }

    private func bootstrap(total: Int) throws {
        try BudgetAdmissionStore(projectRoot: root).bootstrap(
            capacities: [BudgetCapacity(
                resource: .frontierTokens,
                total: total,
                protectedForVerification: 20,
                protectedForRelease: 20
            )],
            periodStartsAt: now,
            periodEndsAt: now.addingTimeInterval(1_000)
        )
    }

    private func exactBudget(
        tokens: Int,
        purpose: BudgetPurpose = .ordinary
    ) -> WorkflowBudgetContract {
        WorkflowBudgetContract(
            purpose: purpose,
            tokenLimit: WorkflowBudgetAmount(
                knowledge: .exact,
                value: tokens,
                unit: "tokens"
            )
        )
    }

    private func task(budget: WorkflowBudgetContract) -> PlanTask {
        PlanTask(
            id: "T1",
            title: "Budgeted task",
            workContract: WorkflowWorkContract(
                revision: 1,
                objective: "Exercise admission",
                approvedProductReference: "decision:budget",
                requirements: [WorkflowRequirement(
                    id: "R1",
                    statement: "Reserve before launch",
                    acceptanceCriteria: ["A durable hold exists"]
                )],
                allowedChangePaths: ["Throttle/"],
                mustPreserve: ["Protected reserves"],
                exclusions: [],
                platforms: [.macOS],
                baseRevision: String(repeating: "a", count: 40),
                inputs: [],
                permissionRequirements: [],
                budget: budget
            )
        )
    }
}
