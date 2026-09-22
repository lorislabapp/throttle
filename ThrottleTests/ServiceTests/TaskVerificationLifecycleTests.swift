@testable import Throttle
import XCTest

final class TaskVerificationLifecycleTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture() throws -> PlanStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verification-\(UUID())")
        let store = PlanStore(projectRoot: root)
        try store.bootstrap(Plan(projectId: "fixture", title: "Fixture", tasks: [PlanTask(id: "task", title: "Task")]))
        try store.append(TaskEvent(seq: 0, timestamp: instant, author: "worker:a", type: .claimed,
                                   missionID: "mission-fixture"), to: "task")
        try store.append(TaskEvent(seq: 0, timestamp: instant, author: "worker:a", type: .candidateComplete),
                         to: "task")
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return store
    }

    private func begin(_ store: PlanStore, now: Date? = nil) throws -> TaskVerificationLease {
        try TaskVerificationLifecycle.begin(taskID: "task", store: store,
            request: .init(command: "true", stamp: "task+base", author: "throttle:fixture", timeout: 1),
            now: now ?? instant)
    }

    private func check(_ lease: TaskVerificationLease) -> TaskEvent {
        let receipt = WorkflowEvidenceReceipt.command("true", stamp: lease.inputStamp, startedAt: instant,
            finishedAt: instant.addingTimeInterval(1), result: (true, true))
        return TaskEvent(seq: 0, timestamp: instant, author: lease.owner, type: .checked,
                         ref: lease.inputStamp, passed: true, receipt: receipt)
    }

    func testReopenedUnacknowledgedExecutionBlocksRetryEvenAfterExpiry() throws {
        let store = try fixture()
        let lease = try begin(store)
        let reopened = PlanStore(projectRoot: store.projectRoot)
        XCTAssertEqual(try reopened.state(for: "task").pendingVerification, lease)
        XCTAssertNil(try reopened.state(for: "task").lastCheck)
        XCTAssertTrue(PlanMCPTools.planReadText(project: store.projectRoot.path)
            .contains("verification_outcome=UNKNOWN"))
        XCTAssertThrowsError(try begin(reopened, now: lease.expiresAt.addingTimeInterval(1))) {
            XCTAssertEqual($0 as? TaskVerificationError, .unresolvedExecution(lease.id))
        }
    }

    func testStoppedObservationDoesNotPassTaskAndFencesLateCompletion() throws {
        let store = try fixture()
        let old = try begin(store)
        XCTAssertThrowsError(try TaskVerificationLifecycle.acknowledgeStoppedExecution(taskID: "task", store: store,
            lease: old, observedBy: "operator", evidenceRef: ""))
        try TaskVerificationLifecycle.acknowledgeStoppedExecution(taskID: "task", store: store, lease: old,
            observedBy: "operator", evidenceRef: "fixture:child-exit-observation", now: instant)
        XCTAssertNil(try store.state(for: "task").lastCheck)
        XCTAssertEqual(try store.state(for: "task").status, .candidate)
        let current = try begin(store)
        XCTAssertGreaterThan(current.fence, old.fence)
        XCTAssertThrowsError(try TaskVerificationLifecycle.finish(taskID: "task", store: store,
            lease: old, checked: check(old), now: instant))
        XCTAssertEqual(try store.state(for: "task").pendingVerification, current)
        _ = try TaskVerificationLifecycle.finish(taskID: "task", store: store, lease: current,
                                              checked: check(current), now: instant)
        XCTAssertEqual(try store.state(for: "task").lastCheck?.passed, true)
        XCTAssertNil(try store.state(for: "task").pendingVerification)
    }

    func testLateSuccessIsIncompleteAndWrongCommandCannotAcknowledge() throws {
        let store = try fixture()
        let lease = try begin(store)
        var wrong = check(lease)
        wrong.receipt?.commandDigest = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try TaskVerificationLifecycle.finish(taskID: "task", store: store,
            lease: lease, checked: wrong, now: instant))
        let observed = try TaskVerificationLifecycle.finish(taskID: "task", store: store, lease: lease,
            checked: check(lease), now: lease.expiresAt)
        XCTAssertEqual(observed.passed, false)
        XCTAssertEqual(observed.receipt?.outcome, .incomplete)
        XCTAssertEqual(try store.state(for: "task").status, .candidate)
    }

    func testLegacyUncheckedAcknowledgementCannotErasePendingExecution() throws {
        let store = try fixture()
        let lease = try begin(store)
        try store.append(check(lease), to: "task")
        let state = try store.state(for: "task")
        XCTAssertEqual(state.pendingVerification, lease)
        XCTAssertNil(state.lastCheck)
        XCTAssertEqual(state.rejected.last?.reason, .staleVerification)
    }

    func testConcurrentControllersAdmitExactlyOneVerification() async throws {
        let store = try fixture()
        let root = store.projectRoot
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    (try? TaskVerificationLifecycle.begin(taskID: "task", store: PlanStore(projectRoot: root),
                        request: .init(command: "true", stamp: "task+base", author: "controller", timeout: 1))) != nil
                }
            }
            var result: [Bool] = []
            for await value in group { result.append(value) }
            return result
        }
        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertEqual(try store.events(for: "task").events.filter { $0.type == .verificationStarted }.count, 1)
    }

    func testVerificationWithoutDurableStoreIsRefusedBeforeCommand() {
        XCTAssertThrowsError(try TaskIntegrationService.verify(taskID: "task", in: URL(fileURLWithPath: "/"),
            command: "true", store: nil, author: "controller")) {
            XCTAssertEqual($0 as? TaskVerificationError, .missingStore)
        }
    }
}
