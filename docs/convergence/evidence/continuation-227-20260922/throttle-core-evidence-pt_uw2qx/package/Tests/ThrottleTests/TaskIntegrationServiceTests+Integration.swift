@testable import Throttle
import XCTest

// MARK: - integrate

/// Integration scenarios share the throwaway repository fixture of the test class.
extension TaskIntegrationServiceTests {

    func test_integrate_fastForwardsTheBaseAndLogsTheSHA() throws {
        let path = try worktree("t1", file: "task.txt", contents: "work\n")
        let store = store()
        try finishTask("t1", in: store)
        try TaskIntegrationService.verify(taskID: "t1", in: repo, command: "true",
                                          store: store, author: "throttle:test")

        // Read before, not after: a successful integration removes the worktree, so
        // there is no `path` left to ask once the merge has landed.
        let taskTip = headSHA(path)

        let sha = try TaskIntegrationService.integrate(taskID: "t1", in: repo, store: store,
                                                       task: PlanTask(id: "t1", title: "T1"),
                                                       author: "throttle:test")
        XCTAssertEqual(sha, taskTip, "the base is now exactly the task's tip")
        XCTAssertEqual(headSHA(), sha)
        let state = try store.state(for: "t1")
        XCTAssertEqual(state.status, .integrated)
        XCTAssertEqual(state.integratedSHA, sha)
    }

    func test_integrate_refusesAnUnverifiedTask() throws {
        try worktree("t1", file: "task.txt", contents: "work\n")
        let store = store()
        try finishTask("t1", in: store)
        XCTAssertThrowsError(try TaskIntegrationService.integrate(
            taskID: "t1", in: repo, store: store,
            task: PlanTask(id: "t1", title: "T1"), author: "throttle:test")) {
            XCTAssertEqual($0 as? TaskIntegrationError, .refused(.unverified))
        }
        XCTAssertEqual(try store.state(for: "t1").status, .done, "nothing moved")
    }

    func test_integrate_refusesWhenTheBaseMovedAfterTheCheck() throws {
        try worktree("t1", file: "task.txt", contents: "work\n")
        let store = store()
        try finishTask("t1", in: store)
        try TaskIntegrationService.verify(taskID: "t1", in: repo, command: "true",
                                          store: store, author: "throttle:test")

        try "elsewhere\n".write(to: repo.appendingPathComponent("other.txt"),
                                atomically: true, encoding: .utf8)
        run(["add", "."]); run(["commit", "-q", "-m", "base moves after the check"])
        let baseBefore = headSHA()

        XCTAssertThrowsError(try TaskIntegrationService.integrate(
            taskID: "t1", in: repo, store: store,
            task: PlanTask(id: "t1", title: "T1"), author: "throttle:test")) {
            // Behind the base is the first thing that is wrong, and the stale check
            // the second — either refusal is correct, an integration is not.
            XCTAssertNotNil($0 as? TaskIntegrationError)
        }
        XCTAssertEqual(headSHA(), baseBefore, "the base was not written to")
    }

    func test_integrate_refusesAGatedTaskWithoutAVerdict() throws {
        try worktree("t1", file: "task.txt", contents: "work\n")
        let store = PlanStore(projectRoot: repo)
        try store.bootstrap(Plan(projectId: "p", title: "P",
                                 tasks: [PlanTask(id: "t1", title: "T1", sotaGate: true)]))
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "claude:a", type: .claimed), to: "t1")
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "claude:a", type: .completed), to: "t1")

        XCTAssertThrowsError(try TaskIntegrationService.integrate(
            taskID: "t1", in: repo, store: store,
            task: PlanTask(id: "t1", title: "T1", sotaGate: true), author: "throttle:test")) {
            XCTAssertEqual($0 as? TaskIntegrationError, .refused(.ungated))
        }
    }

    /// A *tracked* modification — `integrate` deliberately ignores untracked files,
    /// which the verification it just ran is free to leave behind
    /// (`TaskIntegrationRefusalTests` holds both halves of that distinction).
    func test_integrate_refusesADirtyWorktree() throws {
        let path = try worktree("t1", file: "task.txt", contents: "work\n")
        let store = store()
        try finishTask("t1", in: store)
        try TaskIntegrationService.verify(taskID: "t1", in: repo, command: "true",
                                          store: store, author: "throttle:test")
        try "edited after the check\n".write(to: path.appendingPathComponent("task.txt"),
                                             atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try TaskIntegrationService.integrate(
            taskID: "t1", in: repo, store: store,
            task: PlanTask(id: "t1", title: "T1"), author: "throttle:test")) {
            XCTAssertEqual($0 as? TaskIntegrationError, .refused(.dirty))
        }
    }
}

// MARK: - Invalid history must not authorize Git effects

extension TaskIntegrationServiceTests {
    func test_integrateRefusesUnknownEventAfterGreenCheckWithoutMerging() throws {
        try assertInvalidHistoryRefusesGitMutation(unknownEvent: true, rebasing: false)
    }

    func test_integrateRefusesCorruptTailAfterGreenCheckWithoutMerging() throws {
        try assertInvalidHistoryRefusesGitMutation(unknownEvent: false, rebasing: false)
    }

    func test_rebaseRefusesUnknownEventWithoutMovingWorktree() throws {
        try assertInvalidHistoryRefusesGitMutation(unknownEvent: true, rebasing: true)
    }

    func test_rebaseRefusesCorruptTailWithoutMovingWorktree() throws {
        try assertInvalidHistoryRefusesGitMutation(unknownEvent: false, rebasing: true)
    }

    private func assertInvalidHistoryRefusesGitMutation(unknownEvent: Bool, rebasing: Bool) throws {
        let path = try worktree("t1", file: "task.txt", contents: "task work\n")
        let store = store()
        try finishTask("t1", in: store)
        try TaskIntegrationService.verify(taskID: "t1", in: repo, command: "true",
                                          store: store, author: "throttle:test")
        if rebasing {
            try "new base\n".write(to: repo.appendingPathComponent("base-only.txt"),
                                    atomically: true, encoding: .utf8)
            run(["add", "base-only.txt"])
            run(["commit", "-q", "-m", "base advances before refused rebase"])
        }
        let log = repo.appendingPathComponent(".throttle/log/t1.ndjson")
        try damageJournal(log, store: store, unknownEvent: unknownEvent)
        let bytesBefore = try Data(contentsOf: log)
        let state = try store.state(for: "t1")
        XCTAssertFalse(state.chainValid)
        XCTAssertEqual(state.lastCheck?.passed, true, "the readable prefix still contains a green check")
        let baseBefore = headSHA()
        let taskBefore = headSHA(path)
        let statusBefore = run(["status", "--porcelain"], in: path)
        let taskBytes = try Data(contentsOf: path.appendingPathComponent("task.txt"))

        XCTAssertThrowsError(try mutateGit(rebasing: rebasing, store: store)) {
            XCTAssertEqual($0 as? PlanStoreError, .invalidLog("t1"))
        }
        XCTAssertEqual(headSHA(), baseBefore)
        XCTAssertEqual(headSHA(path), taskBefore)
        XCTAssertEqual(run(["status", "--porcelain"], in: path), statusBefore)
        XCTAssertEqual(try Data(contentsOf: path.appendingPathComponent("task.txt")), taskBytes)
        XCTAssertEqual(try Data(contentsOf: log), bytesBefore, "no trimming, migration or acknowledgement")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("task.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent("base-only.txt").path))
    }

    private func mutateGit(rebasing: Bool, store: PlanStore) throws {
        if rebasing {
            _ = try TaskIntegrationService.rebase(taskID: "t1", in: repo)
        } else {
            _ = try TaskIntegrationService.integrate(taskID: "t1", in: repo, store: store,
                                                     task: PlanTask(id: "t1", title: "T1"), author: "throttle:test")
        }
    }

    private func damageJournal(_ log: URL, store: PlanStore, unknownEvent: Bool) throws {
        if unknownEvent {
            // The writer supplies valid seq/prev. Only the final event's kind is changed,
            // so this is an unsupported kind rather than a separately broken hash chain.
            try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "claude:a", type: .progress), to: "t1")
            let text = try String(contentsOf: log, encoding: .utf8)
            XCTAssertTrue(text.contains("\"type\":\"progress\""))
            try text.replacingOccurrences(of: "\"type\":\"progress\"",
                                          with: "\"type\":\"future_verification_result\"")
                .write(to: log, atomically: true, encoding: .utf8)
        } else {
            var data = try Data(contentsOf: log)
            data.append(Data("{\"seq\":".utf8))
            try data.write(to: log)
        }
    }
}
