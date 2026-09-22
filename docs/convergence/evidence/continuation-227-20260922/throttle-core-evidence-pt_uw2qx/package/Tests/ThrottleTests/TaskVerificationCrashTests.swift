import Darwin
import Foundation
@testable import Throttle
import XCTest

final class TaskVerificationCrashTests: XCTestCase {
    func testControllerDiesBeforeAttachmentWithoutRunningProjectCode() throws {
        try exerciseCrash(phase: "before-attach", attached: false)
    }

    func testControllerDiesAfterAttachmentWithoutRunningProjectCode() throws {
        try exerciseCrash(phase: "after-attach", attached: true)
    }

    private func exerciseCrash(phase: String, attached: Bool) throws {
        let executable = try crashWorker()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("throttle-crash-fixture-\(UUID())")
        let store = PlanStore(projectRoot: root)
        try store.bootstrap(Plan(projectId: "fixture", title: "Fixture", tasks: [PlanTask(id: "task", title: "Task")]))
        defer { try? FileManager.default.removeItem(at: root) }
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "worker", type: .claimed), to: "task")
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "worker", type: .candidateComplete), to: "task")
        let worker = Process()
        worker.executableURL = executable
        worker.arguments = [root.path, phase]
        let exited = DispatchSemaphore(value: 0)
        worker.terminationHandler = { _ in exited.signal() }
        try worker.run()
        guard exited.wait(timeout: .now() + 10) == .success else {
            worker.terminate()
            XCTFail("Synthetic controller did not reach the crash point")
            return
        }
        XCTAssertEqual(worker.terminationStatus, 71)
        let text = try String(contentsOf: root.appendingPathComponent("child.pid"), encoding: .utf8)
        let child = try XCTUnwrap(pid_t(text))
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !processIsAbsent(child), ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(processIsAbsent(child), "The gated child must disappear when its controller dies")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("forbidden-marker").path))
        let reopened = PlanStore(projectRoot: root)
        let state = try reopened.state(for: "task")
        XCTAssertNotNil(state.pendingVerification)
        XCTAssertEqual(state.verificationProcess != nil, attached)
        XCTAssertNil(state.lastCheck)
        XCTAssertThrowsError(try TaskVerificationLifecycle.begin(taskID: "task", store: reopened,
            request: .init(command: "true", stamp: "fixture", author: "controller", timeout: 30)),
                             "A crash is not permission to replay")
    }

    private func processIsAbsent(_ pid: pid_t) -> Bool {
        // Failure to inspect native identity alone can mean access was denied.
        // Signal zero has no effect; only ESRCH is accepted as absence here.
        kill(pid, 0) == -1 && errno == ESRCH
    }

    private func crashWorker() throws -> URL {
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<5 {
            let executable = directory.appendingPathComponent("VerificationCrashWorker")
            if FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
            directory.deleteLastPathComponent()
        }
        throw XCTSkip("Requires the isolated core harness's VerificationCrashWorker executable fixture")
    }
}
