@testable import Throttle
import XCTest

/// Plan tab design 1b: the inbox groups leaf tasks by who is blocking, and the
/// detail retells the log without ids or storage keys.
final class PlanInboxTests: XCTestCase {

    /// The viability dossier the design was drawn from: 3 phases, 6 leaves.
    private let plan = Plan(projectId: "p", title: "Viability dossier", tasks: [
        PlanTask(id: "P1", order: 0, title: "Read what is already here"),
        PlanTask(id: "T1.1", parent: "P1", order: 0, title: "Map the codebase: entry points"),
        PlanTask(id: "P2", order: 1, title: "Viability"),
        PlanTask(id: "T2.1", parent: "P2", order: 0, title: "Feasibility: what is buildable", dependsOn: ["T1.1"]),
        PlanTask(id: "T2.2", parent: "P2", order: 1, title: "Competitors: who ships this", dependsOn: ["T1.1"]),
        PlanTask(id: "T2.3", parent: "P2", order: 2, title: "Complaints: in their words", dependsOn: ["T2.2"]),
        PlanTask(id: "T2.4", parent: "P2", order: 3, title: "Missed opportunities"),
        PlanTask(id: "T2.5", parent: "P2", order: 4, title: "Verdict", dependsOn: ["T2.1", "T2.4"])
    ])

    private func state(_ status: TaskStatus) -> TaskState {
        var state = TaskState()
        state.status = status
        return state
    }

    func test_groupsByWhoIsBlocking_leavesOnly_inPlanOrder() {
        let states: [String: TaskState] = [
            "T1.1": state(.integrated),
            "T2.1": state(.done),
            "T2.2": state(.review),
            "T2.4": state(.running)
        ]
        let sections = PlanInbox.sections(plan: plan, states: states)
        XCTAssertEqual(sections.needsYou.map(\.id), ["T2.1", "T2.2"])
        XCTAssertEqual(sections.agentsWorking.map(\.id), ["T2.4"])
        XCTAssertEqual(sections.waiting.map(\.id), ["T2.3", "T2.5"])
        XCTAssertEqual(sections.done.map(\.id), ["T1.1"])
        XCTAssertEqual(sections.leafCount, 6, "phases are never listed")
    }

    func test_readyTaskNeedsItsPerson_unmetOneWaits() {
        XCTAssertEqual(PlanInbox.group(for: .pending, unmetDependencies: []), .needsYou)
        XCTAssertEqual(PlanInbox.group(for: .pending, unmetDependencies: ["T2.2"]), .waiting)
        XCTAssertEqual(PlanInbox.group(for: .blocked, unmetDependencies: []), .waiting)
        XCTAssertEqual(PlanInbox.group(for: .failed, unmetDependencies: []), .needsYou)
        XCTAssertEqual(PlanInbox.group(for: .claimed, unmetDependencies: []), .agentsWorking)
    }

    func test_afterText_namesTheTask_neverItsID() {
        XCTAssertEqual(PlanInbox.afterText(["T2.2"], in: plan), "after Competitors")
        XCTAssertEqual(PlanInbox.afterText(["T2.1", "T2.4"], in: plan), "after 2 tasks")
        XCTAssertNil(PlanInbox.afterText([], in: plan))
        XCTAssertEqual(PlanInbox.dependents(of: "T2.2", in: plan).map(\.id), ["T2.3"])
    }

    func test_story_actorAndChapters() {
        let actor = PlanStory.actor("claudeCode:98AFEFD7-1234")
        XCTAssertEqual(actor.name, AgentRuntime.claudeCode.label)
        XCTAssertEqual(actor.session, "98AFEFD7")

        let start = Date(timeIntervalSince1970: 1_000_000)
        let events = [
            TaskEvent(seq: 1, timestamp: start, author: "claudeCode:a", type: .claimed),
            TaskEvent(seq: 2, timestamp: start.addingTimeInterval(120), author: "claudeCode:a", type: .progress,
                      pct: 30, note: "6 pricing pages collected"),
            TaskEvent(seq: 3, timestamp: start.addingTimeInterval(600), author: "codex:b", type: .verified)
        ]
        let chapters = PlanStory.chapters(events)
        XCTAssertEqual(chapters.map { $0.events.count }, [2, 1])
        XCTAssertEqual(PlanStory.sentence(events[1], parkedForReview: false),
                       "Progress 30% — “6 pricing pages collected”")
    }

    func test_story_sentences_speakInWords() {
        let now = Date()
        let completed = TaskEvent(seq: 5, timestamp: now, author: "claudeCode:a", type: .completed)
        XCTAssertEqual(PlanStory.sentence(completed, parkedForReview: true), "Marked complete → parked for review")
        XCTAssertEqual(PlanStory.sentence(completed, parkedForReview: false), "Marked complete")

        let commit = TaskEvent(seq: 4, timestamp: now, author: "claudeCode:a", type: .evidence,
                               kind: "commit", ref: "a3f9c2e1b7d4")
        XCTAssertEqual(PlanStory.sentence(commit, parkedForReview: false), "Committed a3f9c2e")
        let report = TaskEvent(seq: 3, timestamp: now, author: "claudeCode:a", type: .evidence,
                               kind: "report", ref: "reports/T2.2-competitors.md")
        XCTAssertEqual(PlanStory.sentence(report, parkedForReview: false),
                       "Added the report T2.2-competitors.md")
    }

    func test_shortTitle() {
        XCTAssertEqual(PlanInbox.shortTitle("Map the codebase: entry points"), "Map the codebase")
        XCTAssertEqual(PlanInbox.shortTitle("Verdict"), "Verdict")
        XCTAssertEqual(PlanInbox.shortTitle(": odd"), ": odd")
    }
}
