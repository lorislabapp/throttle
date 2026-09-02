@testable import Throttle
import XCTest

/// Integration writes to the base branch, so every test here runs against a real
/// throwaway repository: what matters is which refusals actually hold when git
/// disagrees with us.
final class TaskIntegrationServiceTests: XCTestCase {

    private var repo = URL(fileURLWithPath: "/")

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

    private func headSHA(_ directory: URL? = nil) -> String {
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

    func test_rebase_refusesADirtyWorktree() throws {
        let path = try worktree("t1", file: "task.txt", contents: "task work\n")
        try "scratch\n".write(to: path.appendingPathComponent("notes.txt"),
                              atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try TaskIntegrationService.rebase(taskID: "t1", in: repo)) {
            XCTAssertEqual($0 as? TaskIntegrationError, .refused(.dirty))
        }
    }
}
