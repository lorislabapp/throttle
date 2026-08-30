@testable import Throttle
import XCTest

/// Intake decides which plan a project gets, so the risk is proposing build work
/// for something that has no decided product, or asking a live codebase to invent
/// itself. Viability scoring is tested for the opposite failure: producing a
/// confident number out of nothing.
final class ProjectIntakeTests: XCTestCase {

    private var repo = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("Skylark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    private func write(_ relative: String, _ contents: String = "x") throws {
        let url = repo.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Survey

    func testEmptyDirectoryIsAnIdeaNotACodebase() {
        let survey = ProjectIntakeService.survey(repo: repo)
        XCTAssertEqual(survey.shape, .empty)
    }

    /// A README and a git init are not a codebase — treating them as one would
    /// skip the questions that decide what gets built.
    func testReadmeOnlyIsStillAnIdea() throws {
        try write("README.md", "# Skylark\n")
        XCTAssertEqual(ProjectIntakeService.survey(repo: repo).shape, .empty)
    }

    func testSourceFilesMakeItUnplannedCode() throws {
        try write("Sources/App.swift", "import Foundation\n")
        try write("Sources/Model.swift", "struct Model {}\n")
        let survey = ProjectIntakeService.survey(repo: repo)
        XCTAssertEqual(survey.shape, .unplannedCode)
        XCTAssertEqual(survey.languages.first, "Swift")
    }

    func testBuildArtefactsAreNotMistakenForSource() throws {
        try write("node_modules/left-pad/index.js", "module.exports = 1\n")
        try write(".build/checkouts/dep/lib.swift", "let x = 1\n")
        XCTAssertEqual(ProjectIntakeService.survey(repo: repo).shape, .empty)
    }

    func testAnExistingPlanEndsIntake() throws {
        try write(".throttle/plan.json", "{}")
        XCTAssertEqual(ProjectIntakeService.survey(repo: repo).shape, .planned)
    }

    // MARK: - Template

    /// The whole product argument: no build task may be reachable before the
    /// viability verdict is done.
    func testBuildAlwaysDependsOnTheViabilityVerdict() {
        for shape in [ProjectIntakeService.Shape.empty, .unplannedCode] {
            let survey = ProjectIntakeService.Survey(
                shape: shape, title: "Skylark", fileCount: 0, languages: [],
                hasReadme: false, hasGitHistory: false, observations: [])
            let plan = PlanTemplate.starter(for: survey)
            let build = plan.tasks.first { $0.parent == "P3" }
            XCTAssertEqual(build?.dependsOn, ["T2.5"], "\(shape) must gate build on the verdict")
            XCTAssertTrue(plan.tasks.contains { $0.id == "T2.5" && $0.sotaGate })
        }
    }

    func testGreenfieldStartsWithTheIdeaAndExistingCodeStartsWithReading() {
        let empty = PlanTemplate.starter(for: .init(
            shape: .empty, title: "Skylark", fileCount: 0, languages: [],
            hasReadme: false, hasGitHistory: false, observations: []))
        let code = PlanTemplate.starter(for: .init(
            shape: .unplannedCode, title: "Skylark", fileCount: 12, languages: ["Swift"],
            hasReadme: true, hasGitHistory: true, observations: []))

        XCTAssertEqual(empty.task("P1")?.title, "Idea")
        XCTAssertEqual(code.task("P1")?.title, "Read what is already here")
        XCTAssertTrue(code.task("T1.1")?.title.contains("Swift") == true)
    }

    func testTemplateProducesAConnectedTree() {
        let plan = PlanTemplate.starter(for: .init(
            shape: .empty, title: "Skylark", fileCount: 0, languages: [],
            hasReadme: false, hasGitHistory: false, observations: []))
        let ids = Set(plan.tasks.map(\.id))
        for task in plan.tasks {
            if let parent = task.parent { XCTAssertTrue(ids.contains(parent), "orphan \(task.id)") }
            for dependency in task.dependsOn {
                XCTAssertTrue(ids.contains(dependency), "\(task.id) depends on missing \(dependency)")
            }
        }
    }

    // MARK: - Viability

    /// The failure mode worth designing against: a number that looks the same
    /// whether it came from evidence or from nothing.
    func testScoringRefusesWhileAPillarIsEmpty() throws {
        let store = ResearchDossierStore(projectRoot: repo)
        try store.record(ResearchFinding(pillar: .feasibility, claim: "SwiftUI can do it",
                                         source: "https://example.com/a", rating: 3,
                                         recordedBy: "codex:a"))
        guard case .insufficientEvidence(let missing) = ViabilityScorer.assess(store.load()) else {
            return XCTFail("expected a refusal, not a score")
        }
        XCTAssertEqual(Set(missing), Set([.competition, .demand, .differentiation]))
    }

    func testScoringWorksOnceEveryPillarHasEvidence() throws {
        let store = ResearchDossierStore(projectRoot: repo)
        for (index, pillar) in ViabilityPillar.allCases.enumerated() {
            try store.record(ResearchFinding(pillar: pillar, claim: "finding \(index)",
                                             source: "https://example.com/\(index)", rating: 3,
                                             recordedBy: "codex:a"))
        }
        guard case .scored(let score, _, let sources) = ViabilityScorer.assess(store.load()) else {
            return XCTFail("expected a score")
        }
        XCTAssertEqual(score, 100)
        XCTAssertEqual(sources, 4)
    }

    func testAFindingWithoutASourceIsRefused() {
        let store = ResearchDossierStore(projectRoot: repo)
        XCTAssertThrowsError(try store.record(
            ResearchFinding(pillar: .demand, claim: "users want it", source: "  ",
                            rating: 3, recordedBy: "codex:a"))) { error in
            XCTAssertEqual(error as? ResearchDossierError, .sourceRequired)
        }
    }

    func testFindingsAccumulateAcrossCalls() throws {
        let store = ResearchDossierStore(projectRoot: repo)
        try store.record(ResearchFinding(pillar: .competition, claim: "one",
                                         source: "https://a", rating: 1, recordedBy: "codex:a"))
        try store.record(ResearchFinding(pillar: .competition, claim: "two",
                                         source: "https://b", rating: 2, recordedBy: "claudeCode:b"))
        XCTAssertEqual(store.load().findings(for: .competition).count, 2)
    }

    // MARK: - Bootstrap

    func testBootstrapWritesAPlanAndThenRefusesToOverwriteIt() throws {
        let first = PlanMCPTools.bootstrapText(project: repo.path)
        XCTAssertTrue(first.contains("Created a plan"))
        XCTAssertTrue(PlanMCPTools.bootstrapText(project: repo.path).contains("already has a plan"))
    }

    func testViabilityTextNamesTheMissingPillars() throws {
        _ = PlanMCPTools.bootstrapText(project: repo.path)
        _ = PlanMCPTools.researchRecordText(PlanMCPTools.FindingRequest(
            project: repo.path, pillar: "feasibility", claim: "buildable",
            source: "https://a", rating: 2, author: "codex:a"))
        let text = PlanMCPTools.viabilityText(project: repo.path)
        XCTAssertTrue(text.contains("insufficient evidence"))
        XCTAssertTrue(text.contains("Competition"))
    }
}
