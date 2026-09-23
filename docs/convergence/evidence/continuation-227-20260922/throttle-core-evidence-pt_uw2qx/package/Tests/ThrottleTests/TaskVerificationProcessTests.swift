import Darwin
import Foundation
@testable import Throttle
import XCTest

final class TaskVerificationProcessTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let store: PlanStore
        let lease: TaskVerificationLease
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verify-process-\(UUID())")
        let store = PlanStore(projectRoot: root)
        try store.bootstrap(Plan(projectId: "fixture", title: "Fixture", tasks: [PlanTask(id: "task", title: "Task")]))
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "worker", type: .claimed), to: "task")
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "worker", type: .candidateComplete), to: "task")
        let lease = try TaskVerificationLifecycle.begin(taskID: "task", store: store,
            request: .init(command: "touch marker", stamp: "fixture", author: "controller", timeout: 30))
        return Fixture(root: root, store: store, lease: lease)
    }

    func testGatedIdentityIsDurableBeforeCommandAndDoesNotCertifyRecovery() throws {
        let fixture = try fixture()
        let (root, store, lease) = (fixture.root, fixture.store, fixture.lease)
        var captured: TaskVerificationProcess?
        let result = TaskIntegrationService.shell("touch marker", in: root, timeout: 5) { child in
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("marker").path))
            let process = try XCTUnwrap(TaskVerificationProcess.captureAdmittedChild(child.pid))
            XCTAssertEqual(process.observe(), .sameRootPresent)
            try TaskVerificationLifecycle.attachProcess(taskID: "task", store: store, lease: lease, process: process)
            let reopened = PlanStore(projectRoot: root)
            XCTAssertEqual(try reopened.state(for: "task").verificationProcess, process)
            XCTAssertTrue(PlanMCPTools.planReadText(project: root.path).contains("process_observation=ROOT_PRESENT"))
            captured = process
        }
        XCTAssertTrue(result.succeeded, result.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("marker").path))
        let process = try XCTUnwrap(captured)
        XCTAssertEqual(process.observe(), .rootExited)
        XCTAssertEqual(try store.state(for: "task").pendingVerification, lease,
                       "Root exit is not a completion or stopped-descendant receipt")
        XCTAssertThrowsError(try TaskVerificationLifecycle.begin(taskID: "task", store: store,
            request: .init(command: "touch marker", stamp: "fixture", author: "controller", timeout: 30)))
    }

    func testFailedAdmissionNeverRunsCommandAndDisablesLateSignals() throws {
        let root = try fixture().root
        var captured: TaskIntegrationService.ChildControl?
        let result = TaskIntegrationService.shell("touch marker", in: root, timeout: 5) { child in
            captured = child
            throw TaskVerificationError.staleExecution
        }
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("marker").path))
        let child = try XCTUnwrap(captured)
        XCTAssertFalse(child.signal(SIGTERM).sent, "Reaped PID/group is no longer signal authority")
        XCTAssertFalse(child.signal(SIGKILL).sent)
    }

    func testDuplicateOrExpiredProcessAttachmentCannotReplaceIdentity() throws {
        let fixture = try fixture()
        let (root, store, lease) = (fixture.root, fixture.store, fixture.lease)
        let result = TaskIntegrationService.shell("true", in: root, timeout: 5) { child in
            let process = try XCTUnwrap(TaskVerificationProcess.captureAdmittedChild(child.pid))
            XCTAssertThrowsError(try TaskVerificationLifecycle.attachProcess(taskID: "task", store: store,
                lease: lease, process: process, now: lease.expiresAt))
            try TaskVerificationLifecycle.attachProcess(taskID: "task", store: store, lease: lease, process: process)
            XCTAssertThrowsError(try TaskVerificationLifecycle.attachProcess(taskID: "task", store: store,
                lease: lease, process: process))
        }
        XCTAssertTrue(result.succeeded, result.output)
        XCTAssertEqual(try store.events(for: "task").events.filter { $0.type == .verificationProcessAttached }.count, 1)
    }

    func testFastTimeoutAlwaysPublishesInterruptionBeforeObservingExit() throws {
        let root = try fixture().root
        for _ in 0..<8 {
            let result = TaskIntegrationService.shell("exec /bin/sleep 5", in: root, timeout: 0.05)
            XCTAssertFalse(result.succeeded)
            XCTAssertTrue(result.output.contains("timed out"), result.output)
            XCTAssertTrue(result.exitObserved, result.output)
        }
    }

    func testObservationDistinguishesReusedPIDAndAnotherBootWithoutSignalling() throws {
        let identity = try XCTUnwrap(NativeProcessIdentity.capture(getpid()))
        let boot = try XCTUnwrap(TaskVerificationProcess.currentBootSession())
        let wrong = NativeProcessIdentity(pid: identity.pid, parentPID: identity.parentPID, userID: identity.userID,
            startedSeconds: identity.startedSeconds + 1, startedMicroseconds: identity.startedMicroseconds)
        XCTAssertEqual(TaskVerificationProcess(identity: wrong, group: identity.pid, bootSession: boot).observe(),
                       .pidReused)
        XCTAssertEqual(TaskVerificationProcess(identity: identity, group: identity.pid, bootSession: UUID()).observe(),
                       .differentBoot)
        XCTAssertNotNil(NativeProcessIdentity.capture(getpid()))
    }
}
