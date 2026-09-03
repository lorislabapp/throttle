@testable import Throttle
import XCTest

/// The refusals that decide whether a stale green can ever reach the base branch,
/// plus the one piece of parsing that decides whether git's own error text gets
/// rendered to the user as a conflict.
///
/// Separate from `TaskIntegrationServiceTests` only because that file is at its
/// length limit; these run against the same kind of throwaway repository, and each
/// one isolates a single guard rather than letting an earlier one fire first.
final class TaskIntegrationRefusalTests: XCTestCase {

    private var repo = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("integration-refusals-\(UUID().uuidString)", isDirectory: true)
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

    private func sha(_ rev: String, in directory: URL? = nil) -> String {
        run(["rev-parse", rev], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A finished task in its own worktree, holding one commit, with a plan that
    /// knows about it.
    @discardableResult
    private func finishedTask(_ id: String, store: PlanStore) throws -> URL {
        let path = try TaskWorktreeService.create(taskID: id, in: repo)
        try "task work\n".write(to: path.appendingPathComponent("task.txt"),
                                atomically: true, encoding: .utf8)
        run(["add", "."], in: path)
        run(["commit", "-q", "-m", "work on \(id)"], in: path)
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "claude:a",
                                   type: .claimed), to: id)
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "claude:a",
                                   type: .completed), to: id)
        return path
    }

    private func makeStore() throws -> PlanStore {
        let store = PlanStore(projectRoot: repo)
        try store.bootstrap(Plan(projectId: "p", title: "P",
                                 tasks: [PlanTask(id: "t1", title: "T1")]))
        return store
    }

    private func integrate(_ store: PlanStore) throws -> String {
        try TaskIntegrationService.integrate(taskID: "t1", in: repo, store: store,
                                             task: PlanTask(id: "t1", title: "T1"),
                                             author: "throttle:test")
    }

    // MARK: - merge-tree parsing

    /// git older than 2.38 does not know `--write-tree`: it exits non-zero after
    /// printing an option error and its usage block. That used to be split on the
    /// first blank line and rendered as "Conflicts with the base in:" over git's own
    /// usage text, with the Integrate button disabled behind it.
    func test_anOptionErrorIsUnknownRatherThanAListOfConflicts() {
        let output = """
        error: unknown option `write-tree'
        usage: git merge-tree [--trivial-merge] <base-tree> <branch1> <branch2>

            -z                    do not quote filenames
            --name-only           list filenames without modes/oids/stages
        """
        XCTAssertEqual(TaskIntegrationService.conflictedPaths(inMergeTreeFailure: output),
                       .unknown)
    }

    func test_aRealConflictKeepsItsPathsAndDropsTheMessages() {
        let oid = String(repeating: "a1b2c3d4", count: 5)
        let output = """
        \(oid)
        src/one.swift
        src/two.swift

        Auto-merging src/one.swift
        CONFLICT (content): Merge conflict in src/one.swift
        """
        XCTAssertEqual(TaskIntegrationService.conflictedPaths(inMergeTreeFailure: output),
                       .conflicted(["src/one.swift", "src/two.swift"]))
    }

    func test_emptyAndTruncatedOutputAreUnknown() {
        XCTAssertEqual(TaskIntegrationService.conflictedPaths(inMergeTreeFailure: ""), .unknown)
        XCTAssertEqual(
            TaskIntegrationService.conflictedPaths(
                inMergeTreeFailure: String(repeating: "f", count: 40)),
            .unknown, "an object id with no paths under it says nothing")
        XCTAssertEqual(
            TaskIntegrationService.conflictedPaths(inMergeTreeFailure: "fatal: bad object\nHEAD"),
            .unknown)
    }
}

// MARK: - The guards on integrate

/// Split from the class body to stay under SwiftLint's `type_body_length`; `private`
/// reaches the helpers above because Swift extends it to same-file extensions.
extension TaskIntegrationRefusalTests {

    /// The lot's central invariant, isolated. Every other stale-green test also
    /// moves the base, so `.behind` fires first and the stamp comparison is never
    /// what refuses: deleting `check.stamp == assessment.stamp` left them all green.
    /// Here the *task* moves instead — an agent that commits once more after the
    /// verification — so the base is untouched, `behindBy` stays 0, the worktree
    /// stays clean, and the stamp is the only thing left that can say no.
    func test_integrate_refusesWhenTheTaskItselfMovedAfterTheCheck() throws {
        let store = try makeStore()
        let path = try finishedTask("t1", store: store)
        try TaskIntegrationService.verify(taskID: "t1", in: repo, command: "true",
                                          store: store, author: "throttle:test")
        let checkedStamp = try store.state(for: "t1").lastCheck?.stamp
        let baseBefore = sha("HEAD")

        try "more work\n".write(to: path.appendingPathComponent("later.txt"),
                                atomically: true, encoding: .utf8)
        run(["add", "."], in: path)
        run(["commit", "-q", "-m", "one more commit after the check"], in: path)

        let assessment = try TaskIntegrationService.assess(taskID: "t1", in: repo)
        XCTAssertEqual(assessment.behindBy, 0, "the base did not move, so .behind cannot fire")
        XCTAssertFalse(assessment.isDirty, "the work is committed, so .dirty cannot fire")
        XCTAssertNotEqual(assessment.stamp, checkedStamp, "the task's side of the stamp moved")

        XCTAssertThrowsError(try integrate(store)) {
            XCTAssertEqual($0 as? TaskIntegrationError, .refused(.unverified))
        }
        XCTAssertEqual(sha("HEAD"), baseBefore, "the base was not written to")
        XCTAssertEqual(try store.state(for: "t1").status, .done, "nothing moved")
    }

    /// `PlanModel` stops on a red verdict before it ever calls `integrate`, so this
    /// guard is only reachable by calling the service directly — which the MCP side
    /// and any later caller can do.
    func test_integrate_refusesARedCheck() throws {
        let store = try makeStore()
        try finishedTask("t1", store: store)
        try TaskIntegrationService.verify(taskID: "t1", in: repo, command: "exit 3",
                                          store: store, author: "throttle:test")
        XCTAssertEqual(try store.state(for: "t1").lastCheck?.passed, false)

        XCTAssertThrowsError(try integrate(store)) {
            XCTAssertEqual($0 as? TaskIntegrationError, .refused(.unverified))
        }
    }

    /// A verification is free to leave build output behind. The fast-forward happens
    /// in the main repo and never reads this worktree, so untracked files are not
    /// its business — otherwise a green ten-minute check would end in `.dirty` with
    /// no way forward from the card.
    func test_integrate_ignoresUntrackedFilesTheVerificationLeftBehind() throws {
        let store = try makeStore()
        let path = try finishedTask("t1", store: store)
        try TaskIntegrationService.verify(taskID: "t1", in: repo,
                                          command: "mkdir -p .build && touch .build/artefact",
                                          store: store, author: "throttle:test")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: path.appendingPathComponent(".build/artefact").path))
        XCTAssertTrue(try TaskIntegrationService.assess(taskID: "t1", in: repo).isDirty,
                      "the strict view still calls this dirty — that is what rebase reads")

        let merged = try integrate(store)
        XCTAssertEqual(sha("HEAD"), merged)
        XCTAssertEqual(try store.state(for: "t1").status, .integrated)
    }

    /// A tracked file modified in the worktree is still a refusal: that is real work
    /// the fast-forward would leave behind.
    func test_integrate_stillRefusesModifiedTrackedFiles() throws {
        let store = try makeStore()
        let path = try finishedTask("t1", store: store)
        try TaskIntegrationService.verify(taskID: "t1", in: repo, command: "true",
                                          store: store, author: "throttle:test")
        try "edited\n".write(to: path.appendingPathComponent("task.txt"),
                             atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try integrate(store)) {
            XCTAssertEqual($0 as? TaskIntegrationError, .refused(.dirty))
        }
    }

    /// On a detached repo HEAD `merge --ff-only` succeeds and advances no branch:
    /// `integrated` would be logged for a merge nothing points at.
    func test_integrate_refusesADetachedRepositoryHEAD() throws {
        let store = try makeStore()
        try finishedTask("t1", store: store)
        try TaskIntegrationService.verify(taskID: "t1", in: repo, command: "true",
                                          store: store, author: "throttle:test")
        let mainBefore = sha("main")
        run(["checkout", "-q", "--detach", "HEAD"])

        XCTAssertThrowsError(try integrate(store)) { error in
            guard case .gitFailed(let message)? = error as? TaskIntegrationError else {
                return XCTFail("expected a gitFailed naming the detached HEAD, got \(error)")
            }
            XCTAssertTrue(message.contains("detached HEAD"), message)
        }
        XCTAssertEqual(sha("main"), mainBefore, "no branch moved")
        XCTAssertEqual(try store.state(for: "t1").status, .done)
    }

    /// The stamp has to describe what the merge will land, which is the branch ref —
    /// `integrate` merges `task/<id>` and `diff` diffs against it. An agent that
    /// checks out a SHA inside its own worktree used to make the stamp describe one
    /// tree while the fast-forward landed another. The assessment follows the branch
    /// rather than refusing, because the branch is what every other step already
    /// reads; a detached worktree simply stops being what is assessed.
    func test_assess_followsTheBranchWhenTheWorktreeHEADIsDetached() throws {
        let store = try makeStore()
        let path = try finishedTask("t1", store: store)
        let tip = sha("task/t1")
        run(["checkout", "-q", "--detach", "HEAD~1"], in: path)
        XCTAssertNotEqual(sha("HEAD", in: path), tip, "the worktree is off the branch")

        let assessment = try TaskIntegrationService.assess(taskID: "t1", in: repo)
        XCTAssertEqual(assessment.taskSHA, tip)
        XCTAssertEqual(assessment.aheadBy, 1)
        XCTAssertEqual(assessment.stamp, "\(tip)+\(sha("HEAD"))")
        XCTAssertEqual(assessment.files, [FileChange(path: "task.txt", added: 1, removed: 0)])
    }
}
