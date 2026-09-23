@testable import Throttle
import XCTest

final class PlanMCPMissionFenceTests: XCTestCase {
    func testOldGrantCannotReportAfterSameAuthorClaimsANewMission() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mission-fence-\(UUID())")
        let store = PlanStore(projectRoot: root)
        try store.bootstrap(Plan(projectId: "fixture", title: "Fixture", tasks: [PlanTask(id: "task", title: "Task")]))
        defer { try? FileManager.default.removeItem(at: root) }
        let old = grant(root)
        let current = grant(root)
        XCTAssertTrue(route("throttle_task_claim", root: root, grant: old).hasPrefix("Claimed"))
        XCTAssertTrue(route("throttle_task_event", root: root, grant: old, type: "released").contains("pending"))
        XCTAssertTrue(route("throttle_task_claim", root: root, grant: current).hasPrefix("Claimed"))
        let count = try store.events(for: "task").events.count
        XCTAssertTrue(route("throttle_task_event", root: root, grant: old, type: "progress").contains("active mission"))
        XCTAssertEqual(try store.events(for: "task").events.count, count)
        XCTAssertTrue(route("throttle_task_event", root: root, grant: current, type: "progress").contains("running"))
        let state = try store.state(for: "task")
        XCTAssertEqual(state.authorityGrantID, current.grantID)
        XCTAssertEqual(state.missionID, current.missionID.uuidString)
    }

    func testClaimCannotSubstituteAnotherMissionAndLegacyClaimIsNotSilentlyBound() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mission-fence-\(UUID())")
        let store = PlanStore(projectRoot: root)
        try store.bootstrap(Plan(projectId: "fixture", title: "Fixture", tasks: [PlanTask(id: "task", title: "Task")]))
        defer { try? FileManager.default.removeItem(at: root) }
        let grant = grant(root)
        var response = ""
        PlanMCPTools.routeTaskCall("throttle_task_claim", ["project": root.path, "task_id": "task",
            "by": "worker", "mission_id": UUID().uuidString], authority: .success(grant),
            { response = $0 }, { response = "error: \($0)" })
        XCTAssertTrue(response.contains("mission"), response)
        XCTAssertTrue(try store.events(for: "task").events.isEmpty)
        _ = PlanMCPTools.claimText(project: root.path, taskID: "task", author: "worker", missionID: nil)
        XCTAssertTrue(route("throttle_task_event", root: root, grant: grant, type: "progress")
            .contains("active mission"))
    }

    private func grant(_ root: URL) -> PlanMCPAuthority {
        PlanMCPAuthority(projectRoots: [root], author: "worker", operations: [.read, .claim, .event],
                         taskID: "task", missionID: UUID(), issuedAt: Date(), expiresAt: Date().addingTimeInterval(60))
    }

    private func route(_ name: String, root: URL, grant: PlanMCPAuthority, type: String = "") -> String {
        var response = ""
        PlanMCPTools.routeTaskCall(name, ["project": root.path, "task_id": "task", "by": "worker", "type": type],
                                  authority: .success(grant), { response = $0 }, { response = "error: \($0)" })
        return response
    }
}
