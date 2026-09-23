import GRDB
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
            "T2": TaskSpend.Entry(taskID: "T2", sessionIDs: [], costEUR: nil)
        ]
        let total = TaskSpend.total(entries)
        XCTAssertEqual(total.costEUR, 1.5, accuracy: 0.0001)
        XCTAssertEqual(total.measured, 1)
        XCTAssertEqual(total.unmeasured, 1)
    }
    func testMissingUsageAndDatabaseFailureAreNotZero() throws {
        let home = try transcriptHome(sessions: ["pending"])
        defer { try? FileManager.default.removeItem(at: home) }
        let database = try DatabaseQueue()
        var entry = TaskSpend.spend(forTasks: ["T1"], projectRoot: URL(fileURLWithPath: "/repo"),
                                   database: database, claudeHome: home)["T1"]
        XCTAssertNil(entry?.costEUR, "missing table must not turn a database error into a free task")
        try Migrations.register(on: database)
        entry = TaskSpend.spend(forTasks: ["T1"], projectRoot: URL(fileURLWithPath: "/repo"),
                               database: database, claudeHome: home)["T1"]
        XCTAssertEqual(entry?.sessionIDs, ["pending"])
        XCTAssertEqual(entry?.measured, false)
        XCTAssertNil(entry?.costEUR, "a transcript without ingested usage is not a measurement")
    }

    func testUsageUsesExistingPricingAndMissingSessionsDoNotUnderstateTotal() throws {
        let home = try transcriptHome(sessions: ["a", "b"])
        defer { try? FileManager.default.removeItem(at: home) }
        let database = try DatabaseQueue()
        try Migrations.register(on: database)
        try database.write { database in
            try database.execute(sql: """
                INSERT INTO usage_events (session_id, timestamp, model, input_tokens)
                VALUES ('a', 1, 'claude-sonnet-4', 1000000)
                """)
        }
        let root = URL(fileURLWithPath: "/repo")
        let pending = TaskSpend.spend(forTasks: ["T1"], projectRoot: root, database: database, claudeHome: home)
        XCTAssertNil(pending["T1"]?.costEUR)
        XCTAssertEqual(TaskSpend.total(pending).unmeasured, 1)
        try database.write { database in
            try database.execute(sql: """
                INSERT INTO usage_events (session_id, timestamp, model, input_tokens)
                VALUES ('b', 1, 'claude-sonnet-4', 0)
                """)
        }
        let measured = TaskSpend.spend(forTasks: ["T1"], projectRoot: root, database: database, claudeHome: home)
        XCTAssertEqual(try XCTUnwrap(measured["T1"]?.costEUR), 2.79, accuracy: 0.0001)
        XCTAssertEqual(TaskSpend.total(measured).measured, 1)
    }

    func testObservedZeroIsStillMeasured() throws {
        let home = try transcriptHome(sessions: ["zero"])
        defer { try? FileManager.default.removeItem(at: home) }
        let database = try DatabaseQueue()
        try Migrations.register(on: database)
        try database.write { database in
            try database.execute(sql: """
                INSERT INTO usage_events (session_id, timestamp, model)
                VALUES ('zero', 1, 'claude-sonnet-4')
                """)
        }
        let entry = TaskSpend.spend(forTasks: ["T1"], projectRoot: URL(fileURLWithPath: "/repo"),
                                   database: database, claudeHome: home)["T1"]
        XCTAssertEqual(entry?.costEUR, 0)
        XCTAssertEqual(entry?.measured, true)
    }

    private func transcriptHome(sessions: [String]) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let folder = home.appending(path: "projects")
            .appending(path: TaskSpend.transcriptFolderName(for: "/repo/.claude/worktrees/T1"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for session in sessions {
            try "{}".write(to: folder.appending(path: "\(session).jsonl"), atomically: true, encoding: .utf8)
        }
        return home
    }

}
