@testable import Throttle
import XCTest

/// Integration writes to the base branch, so every test here runs against a real
/// throwaway repository: what matters is which refusals actually hold when git
/// disagrees with us.
final class TaskIntegrationServiceTests: XCTestCase {

    var repo = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("integration-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        run(["init", "-q", "-b", "main"])
        run(["config", "user.email", "test@example.com"])
        run(["config", "user.name", "Test"])
        try "line one\n".write(to: repo.appendingPathComponent("file.txt"),
                               atomically: true, encoding: .utf8)
        run(["add", "."])
        run(["commit", "-q", "-m", "seed"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    @discardableResult
    func run(_ args: [String], in directory: URL? = nil) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = directory ?? repo
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Not `try?`: a launch that throws (a working directory that no longer
        // exists, say) leaves this process holding the pipe's write end, and the read
        // below then blocks for ever with nothing to show for it.
        do { try process.run() } catch { return String(describing: error) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// A worktree for `id` holding one commit that writes `contents` to `file`.
    @discardableResult
    func worktree(_ id: String, file: String = "file.txt",
                  contents: String) throws -> URL {
        let path = try TaskWorktreeService.create(taskID: id, in: repo)
        try contents.write(to: path.appendingPathComponent(file),
                           atomically: true, encoding: .utf8)
        run(["add", "."], in: path)
        run(["commit", "-q", "-m", "work on \(id)"], in: path)
        return path
    }

    func headSHA(_ directory: URL? = nil) -> String {
        run(["rev-parse", "HEAD"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - assess

    func test_assess_reportsFilesAndAheadCount() throws {
        try worktree("t1", contents: "line one\nline two\n")
        let assessment = try TaskIntegrationService.assess(taskID: "t1", in: repo)
        XCTAssertEqual(assessment.aheadBy, 1)
        XCTAssertEqual(assessment.behindBy, 0)
        XCTAssertFalse(assessment.isDirty)
        XCTAssertEqual(assessment.files, [FileChange(path: "file.txt", added: 1, removed: 0)])
        XCTAssertEqual(assessment.mergeability, .clean)
    }

    func test_assess_namesTheConflictingFileWithoutTouchingTheWorktree() throws {
        let path = try worktree("t1", contents: "task side\n")
        try "base side\n".write(to: repo.appendingPathComponent("file.txt"),
                                atomically: true, encoding: .utf8)
        run(["add", "."]); run(["commit", "-q", "-m", "base moves"])

        let before = headSHA(path)
        let assessment = try TaskIntegrationService.assess(taskID: "t1", in: repo)

        XCTAssertEqual(assessment.mergeability, .conflicted(["file.txt"]))
        XCTAssertEqual(assessment.behindBy, 1)
        XCTAssertEqual(headSHA(path), before, "assessing must not move the worktree")
        XCTAssertTrue(run(["status", "--porcelain"], in: path)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "assessing must not dirty the worktree")
    }

    func test_assess_seesUncommittedWork() throws {
        let path = try worktree("t1", contents: "line one\nline two\n")
        try "scratch\n".write(to: path.appendingPathComponent("notes.txt"),
                              atomically: true, encoding: .utf8)
        XCTAssertTrue(try TaskIntegrationService.assess(taskID: "t1", in: repo).isDirty)
    }

    func test_assess_refusesWhenThereIsNoWorktree() {
        XCTAssertThrowsError(try TaskIntegrationService.assess(taskID: "nope", in: repo)) {
            XCTAssertEqual($0 as? TaskIntegrationError, .noWorktree("nope"))
        }
    }

    func test_diff_returnsTheTextAgainstTheMergeBase() throws {
        try worktree("t1", contents: "line one\nline two\n")
        let text = try TaskIntegrationService.diff(taskID: "t1", in: repo)
        XCTAssertTrue(text.contains("+line two"))
    }

    func test_mergeUsesVerifiedObjectWhenTaskBranchAdvances() throws {
        let path = try worktree("t1", contents: "verified\n")
        let assessed = try TaskIntegrationService.assess(taskID: "t1", in: repo)
        try "unchecked\n".write(to: path.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        run(["add", "."], in: path)
        run(["commit", "-q", "-m", "unchecked later work"], in: path)
        XCTAssertNotEqual(headSHA(path), assessed.taskSHA)

        XCTAssertEqual(try TaskIntegrationService.mergeVerifiedRevision(assessed, in: repo), assessed.taskSHA)
        XCTAssertEqual(headSHA(), assessed.taskSHA)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("file.txt"), encoding: .utf8), "verified\n")
        XCTAssertNotEqual(headSHA(path), headSHA(), "Later agent work must remain outside this integration")
    }

    func test_mergeRefusesWhenAssessedBaseHasChanged() throws {
        try worktree("t1", contents: "verified\n")
        let assessed = try TaskIntegrationService.assess(taskID: "t1", in: repo)
        run(["commit", "--allow-empty", "-q", "-m", "base advances"])
        let changedBase = headSHA()
        XCTAssertThrowsError(try TaskIntegrationService.mergeVerifiedRevision(assessed, in: repo)) {
            XCTAssertEqual($0 as? TaskIntegrationError, .refused(.unverified))
        }
        XCTAssertEqual(headSHA(), changedBase)
    }

    func test_mergeDoesNotExecuteRepositoryHooks() throws {
        try worktree("t1", contents: "verified\n")
        let assessed = try TaskIntegrationService.assess(taskID: "t1", in: repo)
        let hooks = repo.appendingPathComponent(".git/test-hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("post-merge")
        try "#!/bin/sh\ntouch forbidden-hook-marker\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        run(["config", "core.hooksPath", hooks.path])

        XCTAssertEqual(try TaskIntegrationService.mergeVerifiedRevision(assessed, in: repo), assessed.taskSHA)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent("forbidden-hook-marker").path))
        XCTAssertEqual(run(["config", "core.hooksPath"]).trimmingCharacters(in: .whitespacesAndNewlines), hooks.path)
    }

    // MARK: - rebase

    func test_rebase_replaysTheTaskOnTheAdvancedBase() throws {
        try worktree("t1", file: "task.txt", contents: "task work\n")
        try "base work\n".write(to: repo.appendingPathComponent("base.txt"),
                                atomically: true, encoding: .utf8)
        run(["add", "."]); run(["commit", "-q", "-m", "base moves"])

        let after = try TaskIntegrationService.rebase(taskID: "t1", in: repo)
        XCTAssertEqual(after.behindBy, 0, "the task now sits on top of the base")
        XCTAssertEqual(after.aheadBy, 1)
        XCTAssertEqual(after.mergeability, .clean)
    }

    func test_rebase_abortsAndRestoresTheOriginalSHAOnConflict() throws {
        let path = try worktree("t1", contents: "task side\n")
        try "base side\n".write(to: repo.appendingPathComponent("file.txt"),
                                atomically: true, encoding: .utf8)
        run(["add", "."]); run(["commit", "-q", "-m", "base moves"])
        let before = headSHA(path)

        XCTAssertThrowsError(try TaskIntegrationService.rebase(taskID: "t1", in: repo))
        XCTAssertEqual(headSHA(path), before, "an aborted rebase leaves the SHA where it was")
        // `.git` is a file inside a worktree, so probing for a `rebase-merge` directory
        // there would pass no matter what. git's own status is the honest witness.
        XCTAssertFalse(run(["status"], in: path).contains("rebase in progress"),
                       "no rebase is left half-done")
        XCTAssertTrue(run(["status", "--porcelain"], in: path)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Forcing a real `git rebase --abort` to fail requires deliberately corrupting
    /// a worktree's git state, which isn't worth contorting the test setup for — so
    /// this is unit-level coverage of the error case itself: it carries both outputs
    /// distinctly, and stays distinct from a plain `gitFailed`. The `guard abort.ok
    /// else { throw .rebaseAbortFailed(...) }` branch inside `rebase` itself is not
    /// exercised by any test.
    func test_rebaseAbortFailed_carriesBothOutputsAndComparesByValue() {
        let first = TaskIntegrationError.rebaseAbortFailed(
            rebaseOutput: "CONFLICT (content): Merge conflict in file.txt",
            abortOutput: "fatal: no rebase in progress?")
        let identical = TaskIntegrationError.rebaseAbortFailed(
            rebaseOutput: "CONFLICT (content): Merge conflict in file.txt",
            abortOutput: "fatal: no rebase in progress?")
        let differentAbortOutput = TaskIntegrationError.rebaseAbortFailed(
            rebaseOutput: "CONFLICT (content): Merge conflict in file.txt",
            abortOutput: "a different failure")

        XCTAssertEqual(first, identical)
        XCTAssertNotEqual(first, differentAbortOutput)
        XCTAssertNotEqual(first, .gitFailed("CONFLICT (content): Merge conflict in file.txt"),
                          "distinct from a plain gitFailed even with the same rebase output")
    }

    // MARK: - verify

    func store() -> PlanStore {
        let store = PlanStore(projectRoot: repo)
        try? store.bootstrap(Plan(projectId: "p", title: "P",
                                  tasks: [PlanTask(id: "t1", title: "T1")]))
        return store
    }

    func finishTask(_ id: String, in store: PlanStore) throws {
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "claude:a", type: .claimed), to: id)
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "claude:a", type: .completed), to: id)
    }

    func test_rebaseRefusesAnUnresolvedVerification() throws {
        let path = try worktree("t1", file: "task.txt", contents: "work\n")
        let store = store()
        try finishTask("t1", in: store)
        let before = headSHA(path)
        let lease = try TaskVerificationLifecycle.begin(taskID: "t1", store: store,
            request: .init(command: "true", stamp: "fixture", author: "throttle:test", timeout: 10))
        XCTAssertThrowsError(try TaskIntegrationService.rebase(taskID: "t1", in: repo)) {
            XCTAssertEqual($0 as? TaskVerificationError, .unresolvedExecution(lease.id))
        }
        XCTAssertEqual(headSHA(path), before)
        XCTAssertEqual(try store.state(for: "t1").pendingVerification, lease)
    }

    func test_verifyPersistsIntentBeforeLaunchingCommand() throws {
        try worktree("t1", file: "task.txt", contents: "work\n")
        let store = store()
        try finishTask("t1", in: store)
        let log = repo.appendingPathComponent(".throttle/log/t1.ndjson").path
            .replacingOccurrences(of: "'", with: "'\"'\"'")
        let verdict = try TaskIntegrationService.verify(taskID: "t1", in: repo,
            command: "grep -q verification_process_attached '\(log)'", store: store, author: "throttle:test")
        XCTAssertTrue(verdict.passed)
        let events = try store.events(for: "t1").events
        XCTAssertEqual(events.suffix(3).map(\.type), [.verificationStarted, .verificationProcessAttached, .checked])
        XCTAssertEqual(events.last?.verificationLease, events.dropLast().last?.verificationLease)
        XCTAssertNil(try store.state(for: "t1").pendingVerification)
    }

    func test_verify_recordsAGreenCheckStampedWithBothSHAs() throws {
        try worktree("t1", file: "task.txt", contents: "work\n")
        let store = store()
        try finishTask("t1", in: store)

        let verdict = try TaskIntegrationService.verify(taskID: "t1", in: repo, command: "true",
                                                        store: store, author: "throttle:test")
        XCTAssertTrue(verdict.passed)
        let state = try store.state(for: "t1")
        XCTAssertEqual(state.lastCheck?.passed, true)
        XCTAssertEqual(state.lastCheck?.stamp, verdict.stamp)
        XCTAssertEqual(state.status, .done, "verifying does not finish a task")
    }

    func test_verify_recordsAFailureWithItsOutput() throws {
        try worktree("t1", file: "task.txt", contents: "work\n")
        let store = store()
        try finishTask("t1", in: store)

        let verdict = try TaskIntegrationService.verify(taskID: "t1", in: repo,
                                                        command: "echo boom >&2; exit 3",
                                                        store: store, author: "throttle:test")
        XCTAssertFalse(verdict.passed)
        XCTAssertTrue(verdict.output.contains("boom"))
        XCTAssertEqual(try store.state(for: "t1").lastCheck?.passed, false)
    }

    func test_verify_runsInsideTheWorktreeNotTheRepo() throws {
        try worktree("t1", file: "only-here.txt", contents: "task work\n")
        let store = store()
        try finishTask("t1", in: store)

        let verdict = try TaskIntegrationService.verify(taskID: "t1", in: repo,
                                                        command: "test -f only-here.txt",
                                                        store: store, author: "throttle:test")
        XCTAssertTrue(verdict.passed, "the command sees the task's tree, not the base's")
    }

    /// The regression test for the hang `shell()` used to be able to get stuck in:
    /// `readDataToEndOfFile()` blocked on the pipe closing, which a scheduled
    /// `terminate()` alone did not guarantee. A command that would otherwise run
    /// for 30s must come back — failed, with output that says why — close to its
    /// own short timeout, never anywhere near the command's own duration.
    func test_verify_killsAHungCommandAtTheTimeoutAndReportsIt() throws {
        try worktree("t1", file: "task.txt", contents: "work\n")
        let store = store()
        try finishTask("t1", in: store)

        let started = Date()
        let verdict = try TaskIntegrationService.verify(taskID: "t1", in: repo, command: "sleep 30",
                                                        timeout: 1.5, store: store,
                                                        author: "throttle:test")
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(verdict.passed)
        XCTAssertTrue(verdict.output.lowercased().contains("timed out"),
                      "a timeout must say so, not fail silently or come back empty")
        XCTAssertLessThan(elapsed, 10, "verify must not wait anywhere near the command's own 30s")
        XCTAssertEqual(try store.state(for: "t1").lastCheck?.passed, false)
    }
}

// MARK: - Diff failure is not an empty change set

extension TaskIntegrationServiceTests {
    func test_diff_throwsWhenTheTaskReferenceIsMissing() throws {
        try worktree("t1", contents: "line one\nline two\n")
        run(["update-ref", "-d", "refs/heads/task/t1"])

        XCTAssertThrowsError(try TaskIntegrationService.diff(taskID: "t1", in: repo)) { error in
            guard case TaskIntegrationError.gitFailed(let output) = error else {
                return XCTFail("Expected a Git failure, received \(error)")
            }
            XCTAssertFalse(output.isEmpty)
        }
    }
}
