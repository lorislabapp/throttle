@testable import Throttle
import XCTest

final class WorkflowFoundationTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try PlanStore(projectRoot: root).bootstrap(Plan(projectId: "synthetic", title: "Example", tasks: [
            PlanTask(id: "task", title: "One task", sotaGate: true)
        ]))
        return root
    }

    func test_concurrentClaimsAcrossInstancesHaveOneWinner() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            _ = PlanMCPTools.claimText(project: root.path, taskID: "task",
                                      author: "codex:\(index)", missionID: nil)
        }
        let history = try PlanStore(projectRoot: root).events(for: "task")
        XCTAssertTrue(history.chainValid)
        XCTAssertEqual(history.events.count, 1)
        XCTAssertEqual(history.events.first?.type, .claimed)
    }

    func test_concurrentAppendsPreserveAllEventsAndSequence() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            _ = try? PlanStore(projectRoot: root).append(
                TaskEvent(seq: 0, timestamp: Date(), author: "synthetic", type: .evidence,
                          note: String(index)), to: "task")
        }
        let history = try PlanStore(projectRoot: root).events(for: "task")
        XCTAssertTrue(history.chainValid)
        XCTAssertEqual(history.events.map(\.seq), Array(1...32))
        XCTAssertEqual(Set(history.events.compactMap(\.note)).count, 32)
    }

    func test_partialLogIsPreservedAndRejectsAppend() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlanStore(projectRoot: root)
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "a", type: .claimed), to: "task")
        let url = root.appendingPathComponent(".throttle/log/task.ndjson")
        var bytes = try Data(contentsOf: url)
        bytes.append(Data("{\"seq\":2".utf8))
        try bytes.write(to: url)
        XCTAssertThrowsError(try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "a",
                                                        type: .progress), to: "task"))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertFalse(try store.events(for: "task").chainValid)
    }

    func test_eventEndpointCannotBypassCounterReview() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = PlanMCPTools.claimText(project: root.path, taskID: "task", author: "codex:a", missionID: nil)
        for type in ["verified", "rejected", "checked", "integrated", "claimed"] {
            let result = PlanMCPTools.eventText(.init(project: root.path, taskID: "task", author: "codex:a",
                type: type, pct: nil, note: nil, kind: nil, ref: nil, reason: nil, summary: nil))
            XCTAssertTrue(result.hasPrefix("Refused:"), type)
        }
        XCTAssertEqual(try PlanStore(projectRoot: root).events(for: "task").events.count, 1)
    }

    func test_staleOwnerCannotWriteAfterReassignment() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = PlanMCPTools.claimText(project: root.path, taskID: "task", author: "codex:a", missionID: nil)
        _ = PlanMCPTools.eventText(.init(project: root.path, taskID: "task", author: "codex:a",
            type: "released", pct: nil, note: nil, kind: nil, ref: nil, reason: nil, summary: nil))
        _ = PlanMCPTools.claimText(project: root.path, taskID: "task", author: "codex:b", missionID: nil)
        let result = PlanMCPTools.eventText(.init(project: root.path, taskID: "task", author: "codex:a",
            type: "completed", pct: nil, note: nil, kind: nil, ref: nil, reason: nil, summary: nil))
        XCTAssertTrue(result.hasPrefix("Refused:"))
        XCTAssertEqual(try PlanStore(projectRoot: root).state(for: "task").owner, "codex:b")
    }

    func test_symlinkedLogDoesNotWriteOutsideProject() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("untouched.txt")
        try Data("canary".utf8).write(to: target)
        let directory = root.appendingPathComponent(".throttle/log")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("task.ndjson"),
                                                   withDestinationURL: target)
        XCTAssertThrowsError(try PlanStore(projectRoot: root).append(
            TaskEvent(seq: 0, timestamp: Date(), author: "a", type: .claimed), to: "task"))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "canary")
    }

    func test_eventRetryIsIdempotentAndConflictingReuseIsRefused() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlanStore(projectRoot: root)
        var event = TaskEvent(seq: 0, timestamp: Date(), author: "synthetic", type: .evidence)
        let first = try store.append(event, to: "task", expectedSequence: 0)
        let retry = try PlanStore(projectRoot: root).append(event, to: "task", expectedSequence: 0)
        XCTAssertEqual(first.seq, retry.seq)
        XCTAssertEqual(try store.events(for: "task").events.count, 1)
        event.note = "different intent"
        XCTAssertThrowsError(try store.append(event, to: "task")) {
            XCTAssertEqual($0 as? PlanStoreError, .eventIdentityConflict)
        }
        XCTAssertThrowsError(try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "a", type: .evidence),
                                              to: "task", expectedSequence: 0)) {
            XCTAssertEqual($0 as? PlanStoreError, .staleSequence)
        }
    }

    func test_projectLockIsVisibleToAnotherProcessAndReleased() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = """
        import fcntl, sys
        with open(sys.argv[1], 'r+') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                sys.exit(0)
        sys.exit(1)
        """
        func observedContention() throws -> Bool {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            child.arguments = ["python3", "-c", probe, root.appendingPathComponent(".throttle/mutation.lock").path]
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            child.waitUntilExit()
            XCTAssertTrue([0, 1].contains(child.terminationStatus), "the probe must actually run")
            return child.terminationStatus == 0
        }
        try PlanStore(projectRoot: root).mutate { _ in XCTAssertTrue(try observedContention()) }
        XCTAssertFalse(try observedContention())
    }
}
