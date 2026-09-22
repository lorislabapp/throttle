@testable import Throttle
import XCTest

final class WorkflowRecipeTests: XCTestCase {
    private var root = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-recipe-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".throttle"),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCatalogHasThreeVersionedRecipesWithoutAuthorityFields() throws {
        XCTAssertEqual(Set(WorkflowRecipeCatalog.all.map(\.id)), Set(WorkflowRecipeID.allCases))
        XCTAssertTrue(WorkflowRecipeCatalog.all.allSatisfy(\.isValid))
        XCTAssertEqual(Set(WorkflowRecipeCatalog.all.compactMap(\.digest)).count, 3)

        let data = try JSONEncoder().encode(WorkflowRecipeCatalog.all)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in ["command", "permission", "tool", "script"] {
            XCTAssertFalse(json.lowercased().contains("\"\(forbidden)"))
        }
    }

    func testClaimPinsRecipeAndInstructionSnapshot() throws {
        try writePlan(recipe: .bugWithRegression)
        let text = claim()

        XCTAssertTrue(text.contains("Recipe bug-with-regression r1"))
        XCTAssertTrue(text.contains("reproduction, regression-test, test-result"))
        let event = try XCTUnwrap(PlanStore(projectRoot: root).events(for: "T1").events.first)
        XCTAssertEqual(event.recipeID, .bugWithRegression)
        XCTAssertEqual(event.recipeDigest, WorkflowRecipeCatalog.bugWithRegression.digest)
        XCTAssertEqual(event.instructionSnapshotDigest?.count, 64)
    }

    func testCandidateWaitsForEveryCurrentRunEvidenceRequirement() throws {
        try writePlan(recipe: .bugWithRegression)
        _ = claim()
        _ = evidence(kind: "reproduction", ref: "fixture://red")
        _ = evidence(kind: "regression-test", ref: "Tests/testBug")

        let refused = candidate()
        XCTAssertTrue(refused.contains("recipe evidence is missing: test-result"))
        XCTAssertEqual(try PlanStore(projectRoot: root).state(for: "T1").status, .claimed)

        _ = evidence(kind: "test-result", ref: "xcresult://green")
        XCTAssertTrue(candidate().contains("candidate"))
        XCTAssertEqual(try PlanStore(projectRoot: root).state(for: "T1").status, .candidate)
    }

    func testEvidenceWithoutAReferenceDoesNotSatisfyRecipe() throws {
        try writePlan(recipe: .reviewableChange)
        _ = claim()
        _ = evidence(kind: "diff", ref: "")
        _ = evidence(kind: "test-result", ref: "tests://green")
        _ = evidence(kind: "review-summary", ref: "review.md")

        XCTAssertTrue(candidate().contains("recipe evidence is missing: diff"))
    }

    func testEvidenceFromAReleasedRunCannotCompleteANewClaim() throws {
        try writePlan(recipe: .reviewableChange)
        _ = claim()
        for (kind, ref) in [("diff", "git://diff"),
                            ("test-result", "tests://green"),
                            ("review-summary", "review.md")] {
            _ = evidence(kind: kind, ref: ref)
        }
        _ = event(type: "released")
        _ = claim(author: "codex:b")

        let refused = candidate(author: "codex:b")
        XCTAssertTrue(refused.contains("diff, test-result, review-summary"))
    }

    func testInstructionChangeInvalidatesTheClaim() throws {
        try "# Human\n".write(
            to: root.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )
        try writePlan(recipe: .reviewableChange)
        _ = claim()
        for (kind, ref) in [("diff", "git://diff"),
                            ("test-result", "tests://green"),
                            ("review-summary", "review.md")] {
            _ = evidence(kind: kind, ref: ref)
        }
        try "# Human\n\nNew rule.\n".write(
            to: root.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertTrue(candidate().contains("project instructions changed"))
    }

    func testUnavailableRecipeRevisionCannotBeClaimed() throws {
        try writePlan(recipe: .bugWithRegression, revision: 99)

        XCTAssertTrue(claim().contains("unavailable or invalid workflow recipe"))
        XCTAssertTrue(try PlanStore(projectRoot: root).events(for: "T1").events.isEmpty)
    }

    private func writePlan(recipe: WorkflowRecipeID, revision: Int = 1) throws {
        let plan = Plan(
            projectId: "p",
            title: "Recipes",
            tasks: [
                PlanTask(
                    id: "T1",
                    title: "Task",
                    recipe: WorkflowRecipeReference(id: recipe, revision: revision)
                )
            ]
        )
        try PlanStore(projectRoot: root).bootstrap(plan)
    }

    private func claim(author: String = "codex:a") -> String {
        PlanMCPTools.claimText(
            project: root.path,
            taskID: "T1",
            author: author,
            missionID: "M1"
        )
    }

    private func evidence(kind: String, ref: String, author: String = "codex:a") -> String {
        event(type: "evidence", kind: kind, ref: ref, author: author)
    }

    private func candidate(author: String = "codex:a") -> String {
        event(type: "candidate_complete", author: author)
    }

    private func event(
        type: String,
        kind: String? = nil,
        ref: String? = nil,
        author: String = "codex:a"
    ) -> String {
        PlanMCPTools.eventText(PlanMCPTools.EventRequest(
            project: root.path,
            taskID: "T1",
            author: author,
            type: type,
            pct: nil,
            note: nil,
            kind: kind,
            ref: ref,
            reason: nil,
            summary: nil
        ))
    }
}
