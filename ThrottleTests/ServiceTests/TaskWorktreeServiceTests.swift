@testable import Throttle
import XCTest

/// This service deletes directories, so the tests that matter are the refusals.
/// Everything here runs against a real throwaway git repository, because a mock
/// would prove nothing about the one thing at stake: that work an agent produced
/// is never silently removed.
final class TaskWorktreeServiceTests: XCTestCase {

    private var repo = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("worktree-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        run(["init", "-q", "-b", "main"])
        run(["config", "user.email", "test@example.com"])
        run(["config", "user.name", "Test"])
        try "seed\n".write(to: repo.appendingPathComponent("README.md"),
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
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    // MARK: - Create

    func testCreateMakesAWorktreeOnItsOwnBranch() throws {
        let path = try TaskWorktreeService.create(taskID: "T1.1", in: repo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertTrue(run(["branch", "--list", "task/T1.1"]).contains("task/T1.1"))
    }

    /// Relaunching a task must not throw away what its worktree already holds.
    func testCreateIsIdempotent() throws {
        let first = try TaskWorktreeService.create(taskID: "T1.1", in: repo)
        try "in progress\n".write(to: first.appendingPathComponent("work.txt"),
                                  atomically: true, encoding: .utf8)
        let second = try TaskWorktreeService.create(taskID: "T1.1", in: repo)
        XCTAssertEqual(first.path, second.path)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: second.appendingPathComponent("work.txt").path))
    }

    func testUnsafeTaskIDIsRefused() {
        for bad in ["../escape", "a/b", ".hidden", "has space", ""] {
            XCTAssertThrowsError(try TaskWorktreeService.create(taskID: bad, in: repo)) { error in
                XCTAssertEqual(error as? TaskWorktreeError, .unsafeTaskID(bad))
            }
        }
    }

    // MARK: - Removal refusals

    func testRemoveRefusesUncommittedWork() throws {
        let path = try TaskWorktreeService.create(taskID: "T1.1", in: repo)
        try "unsaved\n".write(to: path.appendingPathComponent("draft.txt"),
                              atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try TaskWorktreeService.remove(taskID: "T1.1", in: repo)) { error in
            guard case .hasUnintegratedWork = error as? TaskWorktreeError else {
                return XCTFail("expected a refusal, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testRemoveRefusesUnmergedCommits() throws {
        let path = try TaskWorktreeService.create(taskID: "T1.1", in: repo)
        try "done\n".write(to: path.appendingPathComponent("feature.txt"),
                           atomically: true, encoding: .utf8)
        run(["add", "."], in: path)
        run(["commit", "-q", "-m", "the agent's work"], in: path)

        XCTAssertThrowsError(try TaskWorktreeService.remove(taskID: "T1.1", in: repo,
                                                           base: "main")) { error in
            guard case .hasUnintegratedWork = error as? TaskWorktreeError else {
                return XCTFail("expected a refusal, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testRemoveAcceptsAnEmptyWorktree() throws {
        let path = try TaskWorktreeService.create(taskID: "T1.1", in: repo)
        try TaskWorktreeService.remove(taskID: "T1.1", in: repo, base: "main")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    /// Force exists only for a user who has seen the diff and said to drop it.
    func testForceRemovesWorkOnlyWhenExplicitlyAsked() throws {
        let path = try TaskWorktreeService.create(taskID: "T1.1", in: repo)
        try "unsaved\n".write(to: path.appendingPathComponent("draft.txt"),
                              atomically: true, encoding: .utf8)
        try TaskWorktreeService.remove(taskID: "T1.1", in: repo, base: "main", force: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testRemovingAnAbsentWorktreeIsNotAnError() throws {
        XCTAssertNoThrow(try TaskWorktreeService.remove(taskID: "T9.9", in: repo))
    }

    // MARK: - Status

    func testStatusReportsDirtyAndUnmergedSeparately() throws {
        let path = try TaskWorktreeService.create(taskID: "T1.1", in: repo)
        let fresh = try TaskWorktreeService.status(taskID: "T1.1", in: repo, base: "main")
        XCTAssertTrue(fresh.exists)
        XCTAssertFalse(fresh.holdsWork)

        try "x\n".write(to: path.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let dirty = try TaskWorktreeService.status(taskID: "T1.1", in: repo, base: "main")
        XCTAssertTrue(dirty.isDirty)
        XCTAssertEqual(dirty.unmergedCommits, 0)

        run(["add", "."], in: path)
        run(["commit", "-q", "-m", "work"], in: path)
        let committed = try TaskWorktreeService.status(taskID: "T1.1", in: repo, base: "main")
        XCTAssertFalse(committed.isDirty)
        XCTAssertEqual(committed.unmergedCommits, 1)
    }

    /// The default `base` is "HEAD", which used to be evaluated *inside* the
    /// worktree: `HEAD..HEAD` counts zero whatever the branch holds, so `holdsWork`
    /// silently collapsed to `isDirty` and this call deleted a committed task.
    func testTheDefaultBaseStillSeesUnmergedCommits() throws {
        let path = try TaskWorktreeService.create(taskID: "T1.1", in: repo)
        try "work\n".write(to: path.appendingPathComponent("work.txt"),
                           atomically: true, encoding: .utf8)
        run(["add", "."], in: path)
        run(["commit", "-q", "-m", "work"], in: path)

        let state = try TaskWorktreeService.status(taskID: "T1.1", in: repo)
        XCTAssertFalse(state.isDirty, "the work is committed, so only the count can catch it")
        XCTAssertEqual(state.unmergedCommits, 1)

        XCTAssertThrowsError(try TaskWorktreeService.remove(taskID: "T1.1", in: repo)) {
            XCTAssertEqual($0 as? TaskWorktreeError,
                           .hasUnintegratedWork(
                            "T1.1 still has 1 unmerged commit(s) — look at the diff before it goes away"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }
}
