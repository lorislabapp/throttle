@testable import Throttle
import XCTest

final class TaskSpendTests: XCTestCase {
    func testTranscriptFolderNameFoldsEveryNonAlphanumeric() {
        XCTAssertEqual(
            TaskSpend.transcriptFolderName(for: "/Users/k/GitHub/Éclair/.claude/worktrees/T1.1"),
            "-Users-k-GitHub--clair--claude-worktrees-T1-1"
        )
    }

    func testWorktreePathFollowsTheLaunchersConvention() {
        let root = URL(fileURLWithPath: "/repo", isDirectory: true)
        XCTAssertEqual(TaskSpend.worktree(for: "T2.3", projectRoot: root).path,
                       "/repo/.claude/worktrees/T2.3")
    }

    func testSessionsAreReadFromTheTasksOwnWorktreeFolder() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let root = URL(fileURLWithPath: "/repo", isDirectory: true)
        let folder = home.appending(path: "projects")
            .appending(path: TaskSpend.transcriptFolderName(for: "/repo/.claude/worktrees/T1"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try "{}".write(to: folder.appending(path: "b.jsonl"), atomically: true, encoding: .utf8)
        try "{}".write(to: folder.appending(path: "a.jsonl"), atomically: true, encoding: .utf8)
        try "x".write(to: folder.appending(path: "notes.txt"), atomically: true, encoding: .utf8)

        XCTAssertEqual(TaskSpend.sessionIDs(forTask: "T1", projectRoot: root, claudeHome: home), ["a", "b"])
        XCTAssertEqual(TaskSpend.sessionIDs(forTask: "T2", projectRoot: root, claudeHome: home), [])
    }

    func testTotalsSeparateMeasuredFromUnmeasured() {
        let entries = [
            "T1": TaskSpend.Entry(taskID: "T1", sessionIDs: ["a"], costEUR: 1.5),
            "T2": TaskSpend.Entry(taskID: "T2", sessionIDs: [], costEUR: 0)
        ]
        let total = TaskSpend.total(entries)
        XCTAssertEqual(total.costEUR, 1.5, accuracy: 0.0001)
        XCTAssertEqual(total.measured, 1)
        XCTAssertEqual(total.unmeasured, 1)
    }
}
