@testable import Throttle
import XCTest

/// These tools are the only surface an agent sees, so what matters is what they
/// refuse. A tool that lets two agents both believe they own a task, or lets one
/// report on another's work, corrupts the plan through entirely valid calls.
final class PlanMCPToolsTests: XCTestCase {

    private var root = URL(fileURLWithPath: "/")
    private var project: String { root.path }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".throttle"),
                                                withIntermediateDirectories: true)
        try """
        { "schema": 1, "projectId": "p", "title": "Demo", "tasks": [
          { "id": "P1", "order": 0, "title": "Phase 1" },
          { "id": "T1.1", "parent": "P1", "order": 0, "title": "First", "runtimeHint": "codex" },
          { "id": "T1.2", "parent": "P1", "order": 1, "title": "Second", "dependsOn": ["T1.1"] },
          { "id": "T1.3", "parent": "P1", "order": 2, "title": "Gated", "sotaGate": true }
        ] }
        """.write(to: root.appendingPathComponent(".throttle/plan.json"),
                  atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Read

    func testPlanReadListsOnlyActionableLeaves() {
        let text = PlanMCPTools.planReadText(project: project)
        XCTAssertTrue(text.contains("ACTIONABLE NOW:"))
        XCTAssertTrue(text.contains("T1.1"))
        XCTAssertTrue(text.contains("(suggested: codex)"))
        XCTAssertFalse(text.contains("  P1  Phase 1\n"), "a phase is not work you can pick up")
        XCTAssertFalse(actionableSection(text).contains("T1.2"), "T1.2 depends on T1.1")
    }

    func testPlanReadReportsAnAbsentPlanPlainly() {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-plan-\(UUID().uuidString)")
        let text = PlanMCPTools.planReadText(project: empty.path)
        XCTAssertTrue(text.contains("No plan here"))
    }

    private func actionableSection(_ text: String) -> String {
        guard let range = text.range(of: "ACTIONABLE NOW:") else { return "" }
        return String(text[range.lowerBound...])
    }

    // MARK: - Claim

    func testClaimSucceedsThenBlocksASecondAgent() {
        let first = PlanMCPTools.claimText(project: project, taskID: "T1.1",
                          author: "codex:a", missionID: "M1")
        XCTAssertTrue(first.contains("Claimed T1.1"))

        let second = PlanMCPTools.claimText(project: project, taskID: "T1.1",
                          author: "claude:b", missionID: nil)
        XCTAssertTrue(second.contains("Refused"))
        XCTAssertTrue(second.contains("codex:a"), "the loser should learn who holds it")
    }

    func testClaimRefusesAnUnmetDependency() {
        let text = PlanMCPTools.claimText(project: project, taskID: "T1.2",
                          author: "codex:a", missionID: nil)
        XCTAssertTrue(text.contains("Refused"))
        XCTAssertTrue(text.contains("T1.1"))
    }

    func testClaimRefusesAnUnknownTask() {
        let text = PlanMCPTools.claimText(project: project, taskID: "T9.9",
                          author: "codex:a", missionID: nil)
        XCTAssertTrue(text.contains("Refused"))
    }

    /// The agent is told up front that finishing will not finish it, so it does not
    /// report success to the user on the strength of its own `completed`.
    func testClaimAnnouncesTheSotaGate() {
        let text = PlanMCPTools.claimText(project: project, taskID: "T1.3",
                          author: "codex:a", missionID: nil)
        XCTAssertTrue(text.contains("SOTA-gated"))
    }

    // MARK: - Events

    func testEventRefusedFromANonOwner() {
        _ = PlanMCPTools.claimText(project: project, taskID: "T1.1",
                          author: "codex:a", missionID: nil)
        let text = PlanMCPTools.eventText(PlanMCPTools.EventRequest(
            project: project, taskID: "T1.1", author: "claude:b",
            type: "progress", pct: 90, note: nil, kind: nil,
            ref: nil, reason: nil, summary: nil))
        XCTAssertTrue(text.contains("Refused"))
        XCTAssertTrue(text.contains("codex:a"))
    }

    func testEventRefusedOnAnUnclaimedTask() {
        let text = PlanMCPTools.eventText(PlanMCPTools.EventRequest(
            project: project, taskID: "T1.1", author: "codex:a",
            type: "progress", pct: 10, note: nil, kind: nil,
            ref: nil, reason: nil, summary: nil))
        XCTAssertTrue(text.contains("Claim it first"))
    }

    func testClaimCannotBeForgedThroughTheEventTool() {
        let text = PlanMCPTools.eventText(PlanMCPTools.EventRequest(
            project: project, taskID: "T1.1", author: "codex:a",
            type: "claimed", pct: nil, note: nil, kind: nil,
            ref: nil, reason: nil, summary: nil))
        XCTAssertTrue(text.contains("Refused"))
    }

    func testProgressAndCompletionMoveTheTask() {
        _ = PlanMCPTools.claimText(project: project, taskID: "T1.1",
                          author: "codex:a", missionID: nil)
        let progress = PlanMCPTools.eventText(PlanMCPTools.EventRequest(
            project: project, taskID: "T1.1", author: "codex:a",
            type: "progress", pct: 40, note: nil, kind: nil,
            ref: nil, reason: nil, summary: nil))
        XCTAssertTrue(progress.contains("running"))
        XCTAssertTrue(progress.contains("40%"))

        let done = PlanMCPTools.eventText(PlanMCPTools.EventRequest(
            project: project, taskID: "T1.1", author: "codex:a",
            type: "completed", pct: nil, note: nil, kind: nil,
            ref: nil, reason: nil, summary: "shipped"))
        XCTAssertTrue(done.contains("done"))

        XCTAssertTrue(actionableSection(PlanMCPTools.planReadText(project: project)).contains("T1.2"),
                      "finishing T1.1 must unblock its dependant")
    }

    func testGatedCompletionParksInReviewRatherThanDone() {
        _ = PlanMCPTools.claimText(project: project, taskID: "T1.3",
                          author: "codex:a", missionID: nil)
        let text = PlanMCPTools.eventText(PlanMCPTools.EventRequest(
            project: project, taskID: "T1.3", author: "codex:a",
            type: "completed", pct: nil, note: nil, kind: nil,
            ref: nil, reason: nil, summary: "claims done"))
        XCTAssertTrue(text.contains("review"))
        XCTAssertTrue(text.contains("counter-analysis"))
    }

    func testReleaseHandsTheTaskBack() {
        _ = PlanMCPTools.claimText(project: project, taskID: "T1.1",
                          author: "codex:a", missionID: nil)
        _ = PlanMCPTools.eventText(PlanMCPTools.EventRequest(
            project: project, taskID: "T1.1", author: "codex:a",
            type: "released", pct: nil, note: nil, kind: nil,
            ref: nil, reason: nil, summary: nil))
        let reclaim = PlanMCPTools.claimText(project: project, taskID: "T1.1",
                          author: "claude:b", missionID: nil)
        XCTAssertTrue(reclaim.contains("Claimed T1.1"))
    }
}
