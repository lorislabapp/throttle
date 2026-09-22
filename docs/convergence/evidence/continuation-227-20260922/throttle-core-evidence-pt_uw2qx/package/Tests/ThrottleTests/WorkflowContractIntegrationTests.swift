@testable import Throttle
import XCTest

/// These fixtures exercise real local Git and persistence, without providers.
final class WorkflowContractIntegrationTests: XCTestCase {
    private var repo = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try run(["init", "-q", "-b", "main"])
        try run(["config", "user.email", "test@example.com"])
        try run(["config", "user.name", "Test"])
        try run(["commit", "--allow-empty", "-qm", "seed"])
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: repo)
    }

    private func run(_ args: [String], in directory: URL? = nil) throws {
        let result = TaskIntegrationService.git(args, in: directory ?? repo)
        guard result.ok else { throw TaskIntegrationError.gitFailed(result.output) }
    }

    private func sha(_ revision: String) -> String {
        TaskIntegrationService.git(["rev-parse", revision], in: repo).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeStore(contract: WorkflowVerificationContract? = nil) throws -> PlanStore {
        let store = PlanStore(projectRoot: repo)
        try store.bootstrap(Plan(projectId: "p", title: "P", tasks: [
            PlanTask(id: "t1", title: "T1", verificationContract: contract)
        ]))
        return store
    }

    private func finishedTask(_ id: String, store: PlanStore) throws {
        let path = try TaskWorktreeService.create(taskID: id, in: repo)
        try run(["commit", "--allow-empty", "-qm", "candidate"], in: path)
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "claude:a", type: .claimed), to: id)
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "claude:a",
                                   type: .candidateComplete), to: id)
    }

    private func integrate(_ store: PlanStore) throws -> String {
        try TaskIntegrationService.integrate(taskID: "t1", in: repo, store: store,
            task: PlanTask(id: "t1", title: "T1"), author: "throttle:test")
    }

    func testVerificationPromotesCandidateBeforeIntegration() throws {
        let store = try makeStore()
        try finishedTask("t1", store: store)
        XCTAssertEqual(try store.state(for: "t1").status, .candidate)
        let verdict = try TaskIntegrationService.verify(taskID: "t1", in: repo, command: "true",
                                                        store: store, author: "throttle:test")
        XCTAssertTrue(verdict.passed)
        XCTAssertEqual(try store.state(for: "t1").status, .done)
        let merged = try integrate(store)
        XCTAssertEqual(sha("HEAD"), merged)
        XCTAssertEqual(try store.state(for: "t1").status, .integrated)
    }

    func testContractRefusesExitZeroWithoutTestEvidenceAndPersistsRefusal() throws {
        let contract = WorkflowVerificationContract(revision: 1, requiredTests: ["Suite/testOne"])
        let store = try makeStore(contract: contract)
        try finishedTask("t1", store: store)
        let before = sha("HEAD")
        let verdict = try TaskIntegrationService.verify(taskID: "t1", in: repo, command: "true",
                                                        store: store, author: "throttle:test")
        XCTAssertFalse(verdict.passed)
        XCTAssertTrue(verdict.output.contains("Required test evidence"))
        let reopened = PlanStore(projectRoot: repo)
        let check = try XCTUnwrap(reopened.state(for: "t1").lastCheck)
        XCTAssertFalse(check.passed)
        XCTAssertEqual(check.receipt?.contractDigest, contract.digest)
        XCTAssertThrowsError(try integrate(reopened)) {
            XCTAssertEqual($0 as? TaskIntegrationError, .refused(.unverified))
        }
        XCTAssertEqual(sha("HEAD"), before)
    }

    func testChangedOrRemovedContractInvalidatesPersistedPassingEvidence() throws {
        let contract = WorkflowVerificationContract(revision: 1, requiredTests: ["Suite/testOne"])
        let store = try makeStore(contract: contract)
        try finishedTask("t1", store: store)
        let before = sha("HEAD")
        let stamp = try TaskIntegrationService.assess(taskID: "t1", in: repo).stamp
        var receipt = WorkflowEvidenceReceipt.command("fixture", stamp: stamp, startedAt: Date(),
                                                      finishedAt: Date(), result: (true, true))
        receipt.scope = .testInventory
        receipt.expectedTests = contract.requiredTests
        receipt.passedTests = contract.requiredTests
        receipt.skippedTests = []
        receipt.contractDigest = contract.digest
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "throttle:test", type: .checked,
                                   ref: stamp, passed: true, receipt: receipt), to: "t1")
        var plan = try store.loadPlan()
        for updated in [WorkflowVerificationContract(revision: 2, requiredTests: contract.requiredTests), nil] {
            plan.tasks[0].verificationContract = updated
            try JSONEncoder().encode(plan).write(to: repo.appendingPathComponent(".throttle/plan.json"),
                                                 options: .atomic)
            XCTAssertThrowsError(try integrate(PlanStore(projectRoot: repo))) {
                XCTAssertEqual($0 as? TaskIntegrationError, .refused(.unverified))
            }
            XCTAssertEqual(sha("HEAD"), before)
        }
    }

    func testIntegrationReadsStoredContractDespiteStaleCallerAndGreenCommand() throws {
        let contract = WorkflowVerificationContract(revision: 1, requiredTests: ["Suite/testOne"])
        let store = try makeStore(contract: contract)
        try finishedTask("t1", store: store)
        let stamp = try TaskIntegrationService.assess(taskID: "t1", in: repo).stamp
        let before = sha("HEAD")
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "throttle:test", type: .checked,
                                   ref: stamp, passed: true), to: "t1")
        XCTAssertThrowsError(try integrate(store)) {
            XCTAssertEqual($0 as? TaskIntegrationError, .refused(.unverified))
        }
        XCTAssertEqual(sha("HEAD"), before)
        // Synthetic receipt tests the integration gate, not an actual Xcode run.
        var receipt = WorkflowEvidenceReceipt.command("fixture", stamp: stamp, startedAt: Date(),
                                                      finishedAt: Date(), result: (true, true))
        receipt.scope = .testInventory
        receipt.expectedTests = contract.requiredTests
        receipt.passedTests = contract.requiredTests
        receipt.skippedTests = []
        receipt.contractDigest = contract.digest
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "throttle:test", type: .checked,
                                   ref: stamp, passed: true, receipt: receipt), to: "t1")
        let merged = try integrate(PlanStore(projectRoot: repo))
        XCTAssertEqual(sha("HEAD"), merged)
        XCTAssertEqual(try store.state(for: "t1").status, .integrated)
    }

}
