@testable import Throttle
import XCTest

/// Launching writes to three places at once — a worktree, the task log, and the
/// prompt an agent will believe. These tests hold the invariants that keep those
/// three consistent, especially the ownership re-check that stops two agents from
/// starting on the same task.
final class TaskLauncherTests: XCTestCase {

    private var repo = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".throttle"), withIntermediateDirectories: true)
        git(["init", "-q", "-b", "main"])
        git(["config", "user.email", "test@example.com"])
        git(["config", "user.name", "Test"])
        try "seed\n".write(to: repo.appendingPathComponent("README.md"),
                           atomically: true, encoding: .utf8)
        git(["add", "."])
        git(["commit", "-q", "-m", "seed"])
        try """
        { "schema": 1, "projectId": "p", "title": "Demo", "tasks": [
          { "id": "P1", "order": 0, "title": "Phase" },
          { "id": "T1.1", "parent": "P1", "order": 0, "title": "First" },
          { "id": "T1.2", "parent": "P1", "order": 1, "title": "Second" },
          { "id": "T1.3", "parent": "P1", "order": 2, "title": "Gated", "sotaGate": true }
        ] }
        """.write(to: repo.appendingPathComponent(".throttle/plan.json"),
                  atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    private func git(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = repo
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    func testPrepareCreatesAWorktreeAndClaimsTheTask() throws {
        let plan = try TaskLauncher.prepare(taskID: "T1.1", runtime: .codex,
                                            repo: repo, author: "codex:a", base: "main")

        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.workingDirectory.path))
        XCTAssertEqual(plan.branch, "task/T1.1")
        XCTAssertNotEqual(plan.workingDirectory.path, repo.path,
                          "an agent must never be pointed at the user's own checkout")

        let state = try PlanStore(projectRoot: repo).state(for: "T1.1")
        XCTAssertEqual(state.owner, "codex:a")
        XCTAssertEqual(state.missionID, plan.missionID.uuidString)
    }

    /// The button may have been drawn before another agent claimed the task.
    func testPrepareRefusesATaskSomeoneElseAlreadyHolds() throws {
        _ = try TaskLauncher.prepare(taskID: "T1.1", runtime: .codex,
                                     repo: repo, author: "codex:a", base: "main")

        XCTAssertThrowsError(try TaskLauncher.prepare(taskID: "T1.1", runtime: .claudeCode,
                                                     repo: repo, author: "claude:b",
                                                     base: "main")) { error in
            XCTAssertEqual(error as? TaskLauncher.LaunchError,
                           .alreadyHeld("T1.1", owner: "codex:a"))
        }
    }

    func testPrepareRefusesAnUnknownTask() {
        XCTAssertThrowsError(try TaskLauncher.prepare(taskID: "T9.9", runtime: .codex,
                                                     repo: repo, author: "codex:a",
                                                     base: "main")) { error in
            XCTAssertEqual(error as? TaskLauncher.LaunchError, .unknownTask("T9.9"))
        }
    }

    // MARK: - The prompt the agent believes

    func testKickoffNamesTheBoundaryAndHowToReport() throws {
        let store = PlanStore(projectRoot: repo)
        let plan = try store.loadPlan()
        let text = TaskLauncher.kickoff(for: try XCTUnwrap(plan.task("T1.1")),
                                        author: "codex:a", plan: plan)

        XCTAssertTrue(text.contains("T1.1"))
        XCTAssertTrue(text.contains("worktree of your own"))
        XCTAssertTrue(text.contains("do not merge"))
        XCTAssertTrue(text.contains("throttle_task_event"))
        XCTAssertTrue(text.contains("T1.2"), "it should know which siblings to stay out of")
    }

    /// An agent that thinks `completed` means finished will tell the user it
    /// shipped something that has not been reviewed yet.
    func testKickoffWarnsAboutTheSotaGate() throws {
        let store = PlanStore(projectRoot: repo)
        let plan = try store.loadPlan()
        let gated = TaskLauncher.kickoff(for: try XCTUnwrap(plan.task("T1.3")),
                                         author: "codex:a", plan: plan)
        let plain = TaskLauncher.kickoff(for: try XCTUnwrap(plan.task("T1.1")),
                                         author: "codex:a", plan: plan)

        XCTAssertTrue(gated.contains("SOTA-gated"))
        XCTAssertTrue(gated.contains("Do not report it to the user as finished"))
        XCTAssertFalse(plain.contains("SOTA-gated"))
    }
}
