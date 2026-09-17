import ResearchVaultIPCModel
@testable import Throttle
import XCTest

final class AttemptHistoryTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    private func event(_ seq: Int, _ type: TaskEventType, reason: String? = nil, passed: Bool? = nil,
                       summary: String? = nil) -> TaskEvent {
        TaskEvent(seq: seq, timestamp: epoch.addingTimeInterval(Double(seq)), author: "codex:x", type: type,
                  reason: reason, summary: summary, passed: passed)
    }

    func testOnlyFailuresWithAReasonBecomeLessons() {
        let lessons = AttemptHistory.lessons(taskID: "T1", events: [
            event(1, .claimed), event(2, .progress, reason: "ignored"),
            event(3, .rejected, reason: "Tests were skipped, not run"),
            event(4, .checked, passed: true, summary: "green"),
            event(5, .checked, passed: false, summary: "2 tests failed"),
            event(6, .failed)
        ])
        XCTAssertEqual(lessons.map(\.seq), [3, 5])
    }

    func testFirstAttemptKickoffIsUnchanged() {
        XCTAssertEqual(AttemptHistory.kickoffLines([]), [])
    }

    func testRetryKickoffNamesEarlierFailures() {
        let lessons = AttemptHistory.lessons(taskID: "T1", events: [event(3, .rejected, reason: "No evidence")])
        let lines = AttemptHistory.kickoffLines(lessons)
        XCTAssertTrue(lines.contains { $0.contains("No evidence") })
    }

    func testAppendingTheSameLessonTwiceWritesOneLine() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Project\n".write(to: root.appending(path: "CLAUDE.md"), atomically: true, encoding: .utf8)
        let lesson = AttemptHistory.lessons(taskID: "T1", events: [event(3, .rejected, reason: "Run the tests")])[0]
        XCTAssertTrue(try AttemptHistory.appendToClaudeMd(lesson, projectRoot: root))
        XCTAssertFalse(try AttemptHistory.appendToClaudeMd(lesson, projectRoot: root))
        let content = try String(contentsOf: root.appending(path: "CLAUDE.md"), encoding: .utf8)
        XCTAssertEqual(content.components(separatedBy: "Run the tests").count - 1, 1)
        XCTAssertTrue(content.contains(AttemptHistory.claudeMdHeading))
    }
}

final class AgentRoleTests: XCTestCase {
    func testRoleIsSuggestedFromTheTitle() {
        XCTAssertEqual(AgentRole.suggested(for: PlanTask(id: "a", order: 0, title: "Écrire les tests E2E")),
                       .testWriter)
        XCTAssertEqual(AgentRole.suggested(for: PlanTask(id: "b", order: 0, title: "Audit de sécurité")),
                       .securityRedTeam)
        XCTAssertEqual(AgentRole.suggested(for: PlanTask(id: "c", order: 0, title: "Map the codebase")), .builder)
    }

    func testBuilderLeavesTheKickoffUnchanged() {
        XCTAssertEqual(AgentRole.builder.charter, [])
        XCTAssertFalse(AgentRole.securityRedTeam.charter.isEmpty)
    }
}

final class VaultDocumentBatchingTests: XCTestCase {
    private func payload(_ id: String, bytes: Int) -> ResearchVaultDocumentPayload {
        let content = String(repeating: "a", count: bytes)
        return ResearchVaultDocumentPayload(
            documentID: id, title: id, projectKey: "eclair", category: "notes",
            libraryPath: "notes/\(id).md", origins: [], content: content,
            plaintextSHA256: String(repeating: "0", count: 64), byteCount: bytes,
            modifiedAt: Date(timeIntervalSince1970: 1_790_000_000), sensitivity: "confidential"
        )
    }

    func testBatchesRespectCountAndBytes() {
        let small = (1 ... 9).map { payload("d\($0)", bytes: 10) }
        XCTAssertEqual(small.vaultDocumentBatches(maximumCount: 4, maximumBytes: 1_000).map(\.count), [4, 4, 1])
        let large = (1 ... 3).map { payload("b\($0)", bytes: 400) }
        XCTAssertEqual(large.vaultDocumentBatches(maximumCount: 4, maximumBytes: 500).map(\.count), [1, 1, 1])
    }

    func testAValidPayloadSurvivesValidationAndABadOneDoesNot() throws {
        XCTAssertNoThrow(try payload("d1", bytes: 10).validated())
        let request = ResearchVaultDocumentImportRequest(documents: [payload("d1", bytes: 10),
                                                                     payload("d1", bytes: 10)])
        XCTAssertThrowsError(try request.validated())
    }
}
