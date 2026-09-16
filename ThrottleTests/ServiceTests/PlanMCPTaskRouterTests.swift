@testable import Throttle
import XCTest

final class PlanMCPTaskRouterTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("router-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        try PlanStore(projectRoot: root).bootstrap(Plan(projectId: "example", title: "Example", tasks: [
            PlanTask(id: "task", title: "Task", sotaGate: true)
        ]))
        return root
    }

    private func route(_ name: String, _ arguments: [String: Any]) -> (String?, Int?) {
        var result: String?
        var errorCode: Int?
        PlanMCPTools.routeTaskCall(name, arguments, { result = $0 }, { errorCode = $0.first as? Int })
        return (result, errorCode)
    }

    func test_routerRejectsInvalidMetadataBeforeAnyMutation() throws {
        let root = try fixture()
        for name in ["throttle_task_claim", "throttle_task_event", "throttle_task_verdict"] {
            let response = route(name, ["project": root.path, "task_id": "task", "by": "codex:a",
                                        "type": "progress", "verdict": "verified", "event_id": "bad"])
            XCTAssertNil(response.0)
            XCTAssertEqual(response.1, -32602)
        }
        XCTAssertTrue(try PlanStore(projectRoot: root).events(for: "task").events.isEmpty)
    }

    func test_routerCarriesIdentityAndSequenceThroughClaimEventAndVerdict() throws {
        let root = try fixture()
        let owner: [String: Any] = ["project": root.path, "task_id": "task", "by": "codex:a"]
        let claim = owner.merging(["event_id": UUID().uuidString, "expected_seq": 0]) { _, value in value }
        let completion = owner.merging(["event_id": UUID().uuidString, "expected_seq": 1,
                                        "type": "candidate_complete"]) { _, value in value }
        let verdict: [String: Any] = ["project": root.path, "task_id": "task", "by": "claude:judge",
                                     "verdict": "verified", "event_id": UUID().uuidString, "expected_seq": 3]
        for (name, arguments) in [("throttle_task_claim", claim), ("throttle_task_event", completion)] {
            let first = route(name, arguments)
            XCTAssertNil(first.1)
            XCTAssertFalse(try XCTUnwrap(first.0).hasPrefix("Refused:"))
            let retry = route(name, arguments)
            XCTAssertNil(retry.1)
            XCTAssertTrue(try XCTUnwrap(retry.0).hasPrefix("Already recorded"))
        }
        let store = PlanStore(projectRoot: root)
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "throttle:test",
                                   type: .checked, ref: "candidate+base", passed: true), to: "task")
        let firstVerdict = route("throttle_task_verdict", verdict)
        XCTAssertNil(firstVerdict.1)
        XCTAssertFalse(try XCTUnwrap(firstVerdict.0).hasPrefix("Refused:"))
        let retriedVerdict = route("throttle_task_verdict", verdict)
        XCTAssertNil(retriedVerdict.1)
        XCTAssertTrue(try XCTUnwrap(retriedVerdict.0).hasPrefix("Already recorded"))
        XCTAssertEqual(try store.events(for: "task").events.count, 4)
        XCTAssertEqual(try store.state(for: "task").status, .done)
    }

    func test_routerPreservesLegacyClaimsAndReportsAStaleNewIntent() throws {
        let root = try fixture()
        let owner: [String: Any] = ["project": root.path, "task_id": "task", "by": "codex:a"]
        XCTAssertTrue(try XCTUnwrap(route("throttle_task_claim", owner).0).hasPrefix("Claimed"))
        let stale = owner.merging(["type": "progress", "event_id": UUID().uuidString,
                                   "expected_seq": 0]) { _, value in value }
        XCTAssertTrue(try XCTUnwrap(route("throttle_task_event", stale).0).hasPrefix("Refused:"))
        XCTAssertEqual(try PlanStore(projectRoot: root).events(for: "task").events.count, 1)
    }
}
