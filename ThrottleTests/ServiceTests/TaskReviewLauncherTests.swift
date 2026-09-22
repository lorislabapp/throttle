@testable import Throttle
import XCTest

/// The review button hands the other model family a grant to judge one task —
/// and nothing more: no claim, no progress, no other task.
final class TaskReviewLauncherTests: XCTestCase {

    private var root = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-launcher-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".throttle"),
                                                withIntermediateDirectories: true)
        try """
        { "schema": 1, "projectId": "p", "title": "P", "tasks": [
          { "id": "P1", "order": 0, "title": "Phase" },
          { "id": "D1", "parent": "P1", "order": 0, "title": "Model", "kind": "decision", "sotaGate": true },
          { "id": "D2", "parent": "P1", "order": 1, "title": "Licence", "kind": "decision" }
        ] }
        """.write(to: root.appendingPathComponent(".throttle/plan.json"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var store: PlanStore { PlanStore(projectRoot: root) }

    func testReviewerIsTheOtherFamily() {
        XCTAssertEqual(TaskReviewLauncher.reviewer(for: "codex"), .claudeCode)
        XCTAssertEqual(TaskReviewLauncher.reviewer(for: "claudeCode"), .codex)
        XCTAssertEqual(TaskReviewLauncher.reviewer(for: "human"), .codex)
        XCTAssertEqual(TaskReviewLauncher.reviewer(for: nil), .codex)
    }

    func testReviewGrantMayOnlyReadAndJudgeThisTask() throws {
        _ = try HumanDecisionRecorder.record(
            .init(choice: "Qwen", rationale: "fits"), taskID: "D1", decidedBy: "kevin",
            attempt: .init(), store: store)

        let launch = try TaskReviewLauncher.prepare(taskID: "D1", runtime: .codex, repo: root,
                                                    author: "codex:rev")
        addTeardownBlock { try? FileManager.default.removeItem(at: launch.authorityDescriptor) }

        let grant = try XCTUnwrap(try PlanMCPAuthority.load(
            environment: [PlanMCPAuthority.environmentKey: launch.authorityDescriptor.path]).get())
        XCTAssertEqual(grant.operations, [.read, .verdict])
        XCTAssertEqual(grant.taskID, "D1")
        XCTAssertEqual(grant.author, "codex:rev")
        XCTAssertLessThanOrEqual(grant.expiresAt.timeIntervalSince(grant.issuedAt),
                                 TaskReviewLauncher.grantLifetime)
        // No worktree for a human decision: the reviewer works from the repository.
        XCTAssertEqual(launch.workingDirectory, root)
        XCTAssertTrue(launch.kickoff.contains("throttle_task_verdict"))
        XCTAssertTrue(launch.kickoff.contains("task_id D1"))
        // Preparing a review writes nothing to the task's log.
        XCTAssertEqual(try store.state(for: "D1").status, .review)
    }

    func testRefusesATaskThatIsNotAwaitingReview() throws {
        XCTAssertThrowsError(try TaskReviewLauncher.prepare(taskID: "D2", runtime: .codex, repo: root,
                                                            author: "codex:rev")) { error in
            XCTAssertEqual(error as? TaskReviewLauncher.ReviewError,
                           .notAwaitingReview("D2", status: TaskStatus.pending.rawValue))
        }
    }
}
