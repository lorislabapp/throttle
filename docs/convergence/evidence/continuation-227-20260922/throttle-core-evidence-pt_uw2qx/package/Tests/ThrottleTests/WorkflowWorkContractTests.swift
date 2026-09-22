@testable import Throttle
import XCTest

final class WorkflowWorkContractTests: XCTestCase {
    private var root = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-contract-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".throttle"),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testValidContractHasStableDigestAndExplicitUnknownBudgets() throws {
        let contract = validContract()
        XCTAssertTrue(contract.isValid)
        XCTAssertEqual(contract.digest?.count, 64)
        XCTAssertEqual(contract.digest, contract.digest)
        XCTAssertEqual(contract.budget.tokenLimit.knowledge, .unknown)
        XCTAssertNil(contract.budget.tokenLimit.value)

        let decoded = try JSONDecoder().decode(
            WorkflowWorkContract.self,
            from: JSONEncoder().encode(contract)
        )
        XCTAssertEqual(decoded, contract)
        XCTAssertEqual(decoded.digest, contract.digest)
    }

    func testEveryBoundaryChangeInvalidatesTheEarlierDigest() throws {
        let original = validContract()
        let digest = try XCTUnwrap(original.digest)
        var changed = original
        changed.mustPreserve.append("Keep keyboard focus stable.")
        XCTAssertNotEqual(changed.digest, digest)
        changed = original
        changed.permissionRequirements.append(WorkflowPermissionRequirement(
            capability: "publish",
            action: "upload",
            target: "public release",
            approvalScope: .perAction
        ))
        XCTAssertNotEqual(changed.digest, digest)
        changed = original
        changed.budget.costLimit = WorkflowBudgetAmount(
            knowledge: .exact,
            value: 250,
            unit: "EUR-cent"
        )
        XCTAssertNotEqual(changed.digest, digest)
    }

    func testProductCycleIntentIsPinnedIntoTheTaskBoundary() throws {
        var contract = validContract()
        let initialDigest = try XCTUnwrap(contract.digest)
        contract.productCycle = WorkflowProductCycleContract(
            releaseManifest: WorkflowReleaseManifest(
                releaseID: "throttle-3.7.0-221",
                manifestRevision: 1,
                state: .draft,
                productID: "throttle",
                version: "3.7.0",
                buildNumber: "221",
                sourceRevision: String(repeating: "a", count: 40),
                targets: [WorkflowReleaseTarget(
                    id: "mac-direct",
                    platform: .macOS,
                    distribution: .developerID
                )]
            )
        )
        XCTAssertTrue(contract.isValid)
        XCTAssertNotEqual(contract.digest, initialDigest)

        contract.productCycle = WorkflowProductCycleContract()
        XCTAssertFalse(contract.isValid)
        XCTAssertNil(contract.digest)
    }

    func testUnsafeAndContradictoryContractsFailClosed() {
        var contract = validContract()
        contract.allowedChangePaths = ["../other-project"]
        XCTAssertFalse(contract.isValid)
        XCTAssertNil(contract.digest)

        contract = validContract()
        contract.baseRevision = "main"
        XCTAssertFalse(contract.isValid)

        contract = validContract()
        contract.budget.tokenLimit = WorkflowBudgetAmount(
            knowledge: .unknown,
            value: 100,
            unit: "tokens"
        )
        XCTAssertFalse(contract.isValid)

        let legacy = WorkflowVerificationContract(revision: 2, requiredTests: ["Suite/testOther"])
        let task = PlanTask(
            id: "T1",
            title: "Task",
            verificationContract: legacy,
            workContract: validContract()
        )
        XCTAssertFalse(task.contractIsValid)
    }

    func testPathScopeIsExactOrAnExplicitDirectoryPrefix() {
        let contract = validContract()
        XCTAssertEqual(
            contract.disallowedChanges([
                "Throttle/App.swift",
                "ThrottleTests/Test.swift",
                "README.md",
                "README.md.backup"
            ]),
            ["README.md.backup", "ThrottleTests/Test.swift"]
        )
    }

    func testClaimPinsWorkContractAndChangedPlanCannotCompleteCandidate() throws {
        var plan = Plan(
            projectId: "p",
            title: "Contract",
            tasks: [PlanTask(id: "T1", title: "Task", workContract: validContract())]
        )
        try PlanStore(projectRoot: root).bootstrap(plan)
        XCTAssertTrue(claim().contains("Claimed T1"))
        let claimEvent = try XCTUnwrap(
            PlanStore(projectRoot: root).events(for: "T1").events.first
        )
        XCTAssertEqual(claimEvent.workContractDigest, plan.tasks[0].workContract?.digest)

        plan.tasks[0].workContract?.objective = "A silently changed objective"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(plan).write(
            to: root.appendingPathComponent(".throttle/plan.json"),
            options: .atomic
        )
        let result = PlanMCPTools.eventText(PlanMCPTools.EventRequest(
            project: root.path,
            taskID: "T1",
            author: "codex:a",
            type: "candidate_complete",
            pct: nil,
            note: nil,
            kind: nil,
            ref: nil,
            reason: nil,
            summary: nil
        ))
        XCTAssertTrue(result.contains("work contract changed"))
        XCTAssertEqual(try PlanStore(projectRoot: root).state(for: "T1").status, .claimed)
    }

    func testUnchangedContractMayReachCandidateWithoutInventingRecipeEvidence() throws {
        let plan = Plan(
            projectId: "p",
            title: "Contract",
            tasks: [PlanTask(id: "T1", title: "Task", workContract: validContract())]
        )
        try PlanStore(projectRoot: root).bootstrap(plan)
        _ = claim()
        let result = PlanMCPTools.eventText(PlanMCPTools.EventRequest(
            project: root.path,
            taskID: "T1",
            author: "codex:a",
            type: "candidate_complete",
            pct: nil,
            note: nil,
            kind: nil,
            ref: nil,
            reason: nil,
            summary: "ready"
        ))
        XCTAssertTrue(result.contains("candidate"))
    }

    private func claim() -> String {
        PlanMCPTools.claimText(
            project: root.path,
            taskID: "T1",
            author: "codex:a",
            missionID: "M1"
        )
    }

    private func validContract() -> WorkflowWorkContract {
        WorkflowWorkContract(
            revision: 1,
            objective: "Add a bounded, reviewable workflow contract.",
            approvedProductReference: "decision:workflow-v1",
            requirements: [
                WorkflowRequirement(
                    id: "R1",
                    statement: "Candidate completion is controlled by Throttle.",
                    acceptanceCriteria: ["A worker cannot write done directly."]
                )
            ],
            allowedChangePaths: ["Throttle/", "README.md"],
            mustPreserve: ["Existing human-authored project instructions."],
            exclusions: ["No release or publication."],
            platforms: [.macOS],
            baseRevision: String(repeating: "a", count: 40),
            inputs: [
                WorkflowInputReference(
                    id: "decision",
                    kind: .decision,
                    reference: "decision:workflow-v1"
                )
            ],
            permissionRequirements: [],
            budget: WorkflowBudgetContract(),
            verification: WorkflowVerificationContract(
                revision: 1,
                requiredTests: ["WorkflowWorkContractTests/testContract"]
            )
        )
    }
}
