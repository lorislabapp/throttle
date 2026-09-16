@testable import Throttle
import XCTest

/// A person's decision goes through the same log as agent work. An ungated one
/// counts at once; a SOTA one waits for an agent of another family.
final class HumanDecisionRecorderTests: XCTestCase {

    private var root = URL(fileURLWithPath: "/")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("decision-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".throttle"),
                                                withIntermediateDirectories: true)
        try """
        { "schema": 1, "projectId": "p", "title": "P", "tasks": [
          { "id": "P1", "order": 0, "title": "Phase" },
          { "id": "D1", "parent": "P1", "order": 0, "title": "Licence", "kind": "decision" },
          { "id": "D2", "parent": "P1", "order": 1, "title": "Model", "kind": "decision", "sotaGate": true },
          { "id": "B1", "parent": "P1", "order": 2, "title": "Build", "kind": "build" },
          { "id": "D3", "parent": "P1", "order": 3, "title": "Later", "kind": "decision", "dependsOn": ["B1"] }
        ] }
        """.write(to: root.appendingPathComponent(".throttle/plan.json"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var store: PlanStore { PlanStore(projectRoot: root) }

    func testAnUngatedDecisionCountsAtOnceWithTheChoiceAndReason() throws {
        let state = try HumanDecisionRecorder.record(
            .init(choice: "Keep MIT", rationale: "community first"), taskID: "D1", decidedBy: "kevin",
            attempt: .init(), store: store)
        XCTAssertEqual(state.status, .done)
        XCTAssertEqual(state.summary, "Keep MIT — community first")
        XCTAssertEqual(state.runtime, "human")
    }

    func testASotaDecisionWaitsForAnAgentOfAnotherFamily() throws {
        let state = try HumanDecisionRecorder.record(
            .init(choice: "Keep Qwen 1.7B", rationale: ""), taskID: "D2", decidedBy: "kevin",
            attempt: .init(), store: store)
        XCTAssertEqual(state.status, .review)

        var verdict = TaskEvent(seq: 0, timestamp: now, author: "codex:r1", type: .verified)
        verdict.summary = "consistent with the benchmark"
        try store.append(verdict, to: "D2")
        XCTAssertEqual(try store.state(for: "D2").status, .done, "a reviewer of another family settles it")
    }

    func testADecisionCannotBeRecordedTwice() throws {
        let attempt = HumanDecisionRecorder.Attempt()
        try HumanDecisionRecorder.record(
            .init(choice: "A", rationale: ""), taskID: "D2", decidedBy: "kevin",
                                         attempt: attempt, store: store)
        XCTAssertThrowsError(try HumanDecisionRecorder.record(
            .init(choice: "A", rationale: ""), taskID: "D2", decidedBy: "kevin",
            attempt: attempt, store: store))
        XCTAssertEqual(try store.events(for: "D2").events.count, 2)
    }

    func testOnlyAnOpenDecisionCanBeSettled() throws {
        XCTAssertThrowsError(try HumanDecisionRecorder.record(
            .init(choice: "x", rationale: ""), taskID: "B1", decidedBy: "kevin", attempt: .init(), store: store)) {
            XCTAssertEqual($0 as? HumanDecisionRecorder.RecordError, .notADecision)
        }
        XCTAssertThrowsError(try HumanDecisionRecorder.record(
            .init(choice: "x", rationale: ""), taskID: "D3", decidedBy: "kevin", attempt: .init(), store: store)) {
            XCTAssertEqual($0 as? HumanDecisionRecorder.RecordError, .notOpen(.blocked),
                           "a decision still waiting on its dependencies is not open")
        }
        XCTAssertThrowsError(try HumanDecisionRecorder.record(
            .init(choice: "  ", rationale: ""), taskID: "D1", decidedBy: "kevin", attempt: .init(), store: store)) {
            XCTAssertEqual($0 as? HumanDecisionRecorder.RecordError, .emptyChoice)
        }
    }
}
