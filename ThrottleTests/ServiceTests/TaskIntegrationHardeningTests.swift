@testable import Throttle
import XCTest

/// The two edges successive reviews named on lot F's service, in their own file
/// because `TaskIntegrationServiceTests` is at its length limit: a rebase must not
/// dead-end on build output a verification left behind, and a killed verification
/// must not leave its children running.
///
/// Real throwaway repositories, like the rest of the lot — the point is what git and
/// the kernel actually do, not what we believe they do.
final class TaskIntegrationHardeningTests: XCTestCase {

    private var repo = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("integration-hardening-\(UUID().uuidString)", isDirectory: true)
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
    private func run(_ args: [String], in directory: URL? = nil) -> String {
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
    private func worktree(_ id: String, file: String = "file.txt",
                          contents: String) throws -> URL {
        let path = try TaskWorktreeService.create(taskID: id, in: repo)
        try contents.write(to: path.appendingPathComponent(file),
                           atomically: true, encoding: .utf8)
        run(["add", "."], in: path)
        run(["commit", "-q", "-m", "work on \(id)"], in: path)
        return path
    }

    private func store() -> PlanStore {
        let store = PlanStore(projectRoot: repo)
        try? store.bootstrap(Plan(projectId: "p", title: "P",
                                  tasks: [PlanTask(id: "t1", title: "T1")]))
        return store
    }

    private func finishTask(_ id: String, in store: PlanStore) throws {
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "claude:a",
                                   type: .claimed), to: id)
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "claude:a",
                                   type: .completed), to: id)
    }

    /// Real work in the worktree still refuses: a rebase would replay commits under
    /// edits nobody has committed.
    func test_rebase_refusesModifiedTrackedFiles() throws {
        let path = try worktree("t1", file: "task.txt", contents: "task work\n")
        try "edited in place\n".write(to: path.appendingPathComponent("file.txt"),
                                      atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try TaskIntegrationService.rebase(taskID: "t1", in: repo)) {
            XCTAssertEqual($0 as? TaskIntegrationError, .refused(.dirty))
        }
    }

    /// The dead end this used to be: a failed verification leaves `.build/` in the
    /// worktree, and the strict untracked-inclusive check then refused the *next*
    /// click's rebase — with no click anywhere on the card that could clear it. git
    /// refuses by itself when an untracked file would really be overwritten, and the
    /// abort path restores the worktree when it does.
    func test_rebase_ignoresBuildOutputAVerificationLeftBehind() throws {
        let path = try worktree("t1", file: "task.txt", contents: "task work\n")
        try FileManager.default.createDirectory(at: path.appendingPathComponent(".build"),
                                                withIntermediateDirectories: true)
        try "object code\n".write(to: path.appendingPathComponent(".build/artefact"),
                                  atomically: true, encoding: .utf8)
        try "base work\n".write(to: repo.appendingPathComponent("base.txt"),
                                atomically: true, encoding: .utf8)
        run(["add", "."]); run(["commit", "-q", "-m", "base moves"])

        let assessment = try TaskIntegrationService.assess(taskID: "t1", in: repo)
        XCTAssertTrue(assessment.isDirty, "the untracked-inclusive view still says so")
        XCTAssertFalse(assessment.hasLooseWork, "but no tracked file was touched")

        let after = try TaskIntegrationService.rebase(taskID: "t1", in: repo)
        XCTAssertEqual(after.behindBy, 0, "the rebase happened rather than being refused")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: path.appendingPathComponent(".build/artefact").path),
                      "and git left the untracked file alone")
    }

    /// The leak the timeout used to leave behind. `/bin/sh -c "swift test"` signalled
    /// on its pid alone dies while the compiler and the test binaries it started keep
    /// running — holding the pipe and, on a 16 GB machine, the RAM. The child is
    /// spawned as the leader of its own process group precisely so the deadline can
    /// reach all of it.
    ///
    /// The command backgrounds a grandchild that outlives its parent, records that
    /// grandchild's pid, and would touch a marker a few seconds later. Both halves are
    /// asserted: the pid is gone, and the marker it would have written never appears.
    func test_verify_leavesNoDescendantRunningAfterATimeout() throws {
        let path = try worktree("t1", file: "task.txt", contents: "work\n")
        let store = store()
        try finishTask("t1", in: store)
        let command = "sh -c 'echo $$ > orphan.pid; sleep 4; touch orphan.marker' & echo started; wait"

        let verdict = try TaskIntegrationService.verify(taskID: "t1", in: repo, command: command,
                                                        timeout: 1, store: store,
                                                        author: "throttle:test")
        XCTAssertFalse(verdict.passed)

        let orphan = try XCTUnwrap(pid(at: path.appendingPathComponent("orphan.pid")),
                                   "the command must actually have started a grandchild")
        XCTAssertTrue(waitUntilGone(orphan),
                      "the timeout killed the shell's process group, not only the shell")
        // The marker is due 4s in; wait past it rather than concluding from its
        // absence at the moment the kill landed.
        Thread.sleep(forTimeInterval: 4)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: path.appendingPathComponent("orphan.marker").path),
                       "a killed descendant writes nothing after its deadline")
    }

    /// The half the SIGTERM-obeying test above passes straight over. The escalation
    /// used to be cancelled the instant the group *leader* exited, so a descendant
    /// that traps or ignores SIGTERM outlived the shell and nothing ever sent it the
    /// SIGKILL — the compiler still holding the RAM, which is the whole point of
    /// putting the child in its own group. The escalation is released on the group
    /// being empty now, not on the leader being gone.
    ///
    /// `trap "" TERM` is inherited across fork and exec, so the whole background
    /// subtree ignores SIGTERM; only SIGKILL can end it.
    func test_verify_killsADescendantThatIgnoresSIGTERM() throws {
        let path = try worktree("t1", file: "task.txt", contents: "work\n")
        let store = store()
        try finishTask("t1", in: store)
        let command = "sh -c 'trap \"\" TERM; echo $$ > orphan.pid; sleep 4;"
            + " touch orphan.marker' & echo started; wait"

        let verdict = try TaskIntegrationService.verify(taskID: "t1", in: repo, command: command,
                                                        timeout: 1, store: store,
                                                        author: "throttle:test")
        XCTAssertFalse(verdict.passed)

        let orphan = try XCTUnwrap(pid(at: path.appendingPathComponent("orphan.pid")),
                                   "the command must actually have started a grandchild")
        XCTAssertTrue(waitUntilGone(orphan),
                      "SIGTERM was ignored, so the escalation had to reach it — and did")
        // SIGKILL lands at timeout + killGracePeriod, a second before the marker was
        // due; wait past that due time rather than concluding from its absence early.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: path.appendingPathComponent("orphan.marker").path),
                       "a killed descendant writes nothing after its deadline")
    }

    /// The mirror image of the two timeout tests, and the reason the timeout verdict
    /// is fenced separately from the signal itself. A command that exits cleanly and
    /// deliberately leaves something running has not timed out, however non-empty its
    /// process group is when the deadline machinery is torn down — and it must not be
    /// waited on either, because nothing here asked it to stop.
    func test_verify_passesWhenASuccessfulCommandLeavesSomethingRunning() throws {
        let path = try worktree("t1", file: "task.txt", contents: "work\n")
        let store = store()
        try finishTask("t1", in: store)
        let command = "sleep 30 & echo $! > survivor.pid; echo done; exit 0"

        let started = Date()
        let verdict = try TaskIntegrationService.verify(taskID: "t1", in: repo, command: command,
                                                        timeout: 30, store: store,
                                                        author: "throttle:test")
        let elapsed = Date().timeIntervalSince(started)

        // The survivor holds the pipe's write end, so the bounded drain is what ends
        // this — not the survivor, and not the timeout.
        let survivor = try XCTUnwrap(pid(at: path.appendingPathComponent("survivor.pid")))
        defer { kill(survivor, SIGKILL) }
        XCTAssertTrue(verdict.passed, verdict.output)
        XCTAssertFalse(verdict.output.lowercased().contains("timed out"), verdict.output)
        XCTAssertLessThan(elapsed, 15, "and it did not wait for what the command left behind")
        XCTAssertEqual(try store.state(for: "t1").lastCheck?.passed, true)
    }

    /// The pid the backgrounded grandchild wrote, once it has written it.
    private func pid(at file: URL) -> pid_t? {
        for _ in 0..<100 {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    /// `kill(pid, 0)` probes for a process without signalling it. Polled rather than
    /// read once: SIGKILL delivery and the reparented child's reaping are both
    /// asynchronous, and asserting on timing is what this suite avoids.
    private func waitUntilGone(_ target: pid_t) -> Bool {
        for _ in 0..<150 {
            if kill(target, 0) != 0 { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }
}
