@testable import Throttle
import XCTest

final class PlanMCPRetryTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plan-retry-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        try PlanStore(projectRoot: root).bootstrap(Plan(projectId: "example", title: "Synthetic", tasks: [
            PlanTask(id: "task", title: "Task", sotaGate: true)
        ]))
        return root
    }

    private func event(_ root: URL, type: String, sequence: Int) -> PlanMCPTools.EventRequest {
        .init(project: root.path, taskID: "task", author: "codex:a", type: type,
              pct: nil, note: nil, kind: nil, ref: nil, reason: nil, summary: nil,
              retry: .init(eventID: UUID(), expectedSequence: sequence))
    }

    func test_jsonRetryMetadataRejectsPartialMalformedAndBooleanValues() throws {
        let identity = UUID().uuidString
        let valid = try PlanMCPTools.MutationRetry.decode(["event_id": identity, "expected_seq": 0])
        XCTAssertEqual(valid.eventID?.uuidString, identity)
        XCTAssertEqual(valid.expectedSequence, 0)
        XCTAssertNil(try PlanMCPTools.MutationRetry.decode(nil).eventID)
        for value: Any in [true, false, -1, 1.5, "0", NSNull(), 9_007_199_254_740_992] {
            let data = try JSONSerialization.data(withJSONObject: ["event_id": identity, "expected_seq": value])
            let args = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertThrowsError(try PlanMCPTools.MutationRetry.decode(args))
        }
        for args: [String: Any] in [["event_id": identity], ["expected_seq": 0],
                                   ["event_id": "not-a-uuid", "expected_seq": 0]] {
            XCTAssertThrowsError(try PlanMCPTools.MutationRetry.decode(args))
        }
    }

    func test_concurrentIdenticalClaimRetriesWriteOneEvent() throws {
        let root = try fixture()
        let retry = PlanMCPTools.MutationRetry(eventID: UUID(), expectedSequence: 0)
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            _ = PlanMCPTools.claimText(project: root.path, taskID: "task", author: "codex:a",
                                      missionID: "example", retry: retry)
        }
        let history = try PlanStore(projectRoot: root).events(for: "task")
        XCTAssertTrue(history.chainValid)
        XCTAssertEqual(history.events.count, 1)
        XCTAssertEqual(history.events.first?.eventID, retry.eventID)
        XCTAssertTrue(PlanMCPTools.planReadText(project: root.path).contains("seq=1"))
    }

    func test_lostReleaseResponseCanBeRetriedAfterReassignmentWithoutReclaiming() throws {
        let root = try fixture()
        let claim = PlanMCPTools.MutationRetry(eventID: UUID(), expectedSequence: 0)
        _ = PlanMCPTools.claimText(project: root.path, taskID: "task", author: "codex:a",
                                  missionID: nil, retry: claim)
        let release = event(root, type: "released", sequence: 1)
        XCTAssertFalse(PlanMCPTools.eventText(release).hasPrefix("Refused:"))
        _ = PlanMCPTools.claimText(project: root.path, taskID: "task", author: "codex:b", missionID: nil)
        XCTAssertTrue(PlanMCPTools.eventText(release).hasPrefix("Already recorded"))
        XCTAssertTrue(PlanMCPTools.claimText(project: root.path, taskID: "task", author: "codex:a",
            missionID: nil, retry: claim).hasPrefix("Already recorded"))
        let store = PlanStore(projectRoot: root)
        XCTAssertEqual(try store.events(for: "task").events.count, 3)
        XCTAssertEqual(try store.state(for: "task").owner, "codex:b")
    }

    func test_changedPayloadAuthorAndExpectedSequenceAreNotValidRetries() throws {
        let root = try fixture()
        _ = PlanMCPTools.claimText(project: root.path, taskID: "task", author: "codex:a", missionID: nil)
        let request = event(root, type: "progress", sequence: 1)
        XCTAssertFalse(PlanMCPTools.eventText(request).hasPrefix("Refused:"))
        var changed = request
        changed.note = "different intent"
        XCTAssertTrue(PlanMCPTools.eventText(changed).hasPrefix("Refused:"))
        changed = request
        changed.author = "codex:b"
        XCTAssertTrue(PlanMCPTools.eventText(changed).hasPrefix("Refused:"))
        changed = request
        changed.retry.expectedSequence = 2
        XCTAssertTrue(PlanMCPTools.eventText(changed).hasPrefix("Refused:"))
        XCTAssertEqual(try PlanStore(projectRoot: root).events(for: "task").events.count, 2)
    }

    func test_staleNewEventIsRefusedEvenWhenTheSameAuthorOwnsANewClaim() throws {
        let root = try fixture()
        _ = PlanMCPTools.claimText(project: root.path, taskID: "task", author: "codex:a", missionID: nil)
        let stale = event(root, type: "completed", sequence: 1)
        _ = PlanMCPTools.eventText(event(root, type: "released", sequence: 1))
        _ = PlanMCPTools.claimText(project: root.path, taskID: "task", author: "codex:a", missionID: nil)
        XCTAssertTrue(PlanMCPTools.eventText(stale).hasPrefix("Refused:"))
        XCTAssertEqual(try PlanStore(projectRoot: root).state(for: "task").status, .claimed)
    }

    func test_verdictRetryDoesNotIncrementRejectionCountTwice() throws {
        let root = try fixture()
        _ = PlanMCPTools.claimText(project: root.path, taskID: "task", author: "codex:a", missionID: nil)
        _ = PlanMCPTools.eventText(event(root, type: "completed", sequence: 1))
        let request = PlanMCPTools.VerdictRequest(project: root.path, taskID: "task", author: "claude:judge",
            verdict: "rejected", reason: "Missing test", summary: nil,
            retry: .init(eventID: UUID(), expectedSequence: 2))
        XCTAssertFalse(PlanMCPTools.verdictText(request).hasPrefix("Refused:"))
        XCTAssertTrue(PlanMCPTools.verdictText(request).hasPrefix("Already recorded"))
        let store = PlanStore(projectRoot: root)
        XCTAssertEqual(try store.state(for: "task").rejectionCount, 1)
        XCTAssertEqual(try store.events(for: "task").events.count, 3)
    }
}
