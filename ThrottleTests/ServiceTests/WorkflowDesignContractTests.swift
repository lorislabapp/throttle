@testable import Throttle
import XCTest

final class WorkflowDesignContractTests: XCTestCase {
    func testCompleteJourneyHasAStableDigestAndExplicitUnavailableTool() throws {
        let design = validDesign()
        XCTAssertTrue(design.isValid)
        XCTAssertEqual(design.digest, design.digest)
        XCTAssertEqual(design.designTool.availability, .unavailable)
        XCTAssertNotNil(design.designTool.unavailableReason)
    }

    func testEveryRuntimeStateMustBeCoveredOrExplicitlyNotApplicable() {
        var design = validDesign()
        design.states.removeAll { $0.kind == .error }
        XCTAssertFalse(design.isValid)

        design = validDesign()
        design.states[0] = WorkflowDesignState(
            kind: .loading,
            disposition: .notApplicable,
            behavior: nil,
            notApplicableReason: nil
        )
        XCTAssertFalse(design.isValid)
    }

    func testChangingCopyChangesTheDesignAndWorkContractDigests() throws {
        let first = workContract(design: validDesign(), rubric: validRubric())
        var changedDesign = validDesign()
        changedDesign.copyRequirements[0] = "Use a direct, actionable empty-state sentence."
        let second = workContract(design: changedDesign, rubric: validRubric())

        XCTAssertNotEqual(try XCTUnwrap(first.design?.digest), try XCTUnwrap(second.design?.digest))
        XCTAssertNotEqual(try XCTUnwrap(first.digest), try XCTUnwrap(second.digest))
    }

    func testDesignRequiresReviewDimensionsAndCompatibleEvidence() {
        XCTAssertFalse(workContract(design: validDesign(), rubric: nil).isValid)

        var rubric = validRubric()
        rubric.criteria.removeAll { $0.dimension == .accessibility }
        XCTAssertFalse(workContract(design: validDesign(), rubric: rubric).isValid)

        rubric = validRubric()
        let index = rubric.criteria.firstIndex { $0.dimension == .platform } ?? 0
        rubric.criteria[index].acceptedEvidenceKinds = ["mockup"]
        XCTAssertFalse(workContract(design: validDesign(), rubric: rubric).isValid)
    }

    private func validDesign() -> WorkflowDesignContract {
        WorkflowDesignContract(
            revision: 1,
            id: "candidate-review-journey",
            goal: "Understand why a candidate is accepted or refused.",
            entryPoint: "Plan inspector",
            steps: [
                WorkflowDesignJourneyStep(
                    id: "open",
                    action: "Open a candidate task.",
                    expectedResult: "The contract, evidence and next action are visible."
                )
            ],
            states: states(),
            components: ["Task tree", "Inspector", "Review cards"],
            copyRequirements: ["Name the next action and the missing proof."],
            accessibility: accessibilityRequirements(),
            platformAdaptations: [
                WorkflowDesignPlatformAdaptation(
                    platform: .macOS,
                    behavior: "Use native split view, keyboard navigation and VoiceOver."
                )
            ],
            evidenceRequirements: designEvidenceRequirements(),
            designTool: WorkflowDesignToolStatus(
                tool: "Claude Design",
                availability: .unavailable,
                evidenceRef: nil,
                unavailableReason: "No verified integration is available in this runtime."
            )
        )
    }

    private func states() -> [WorkflowDesignState] {
        [
                WorkflowDesignState(
                    kind: .loading,
                    disposition: .required,
                    behavior: "Show progress without stealing keyboard focus."
                ),
                WorkflowDesignState(
                    kind: .ready,
                    disposition: .required,
                    behavior: "Show the exact review criteria and evidence."
                ),
                WorkflowDesignState(
                    kind: .empty,
                    disposition: .required,
                    behavior: "Explain which evidence is still missing."
                ),
                WorkflowDesignState(
                    kind: .error,
                    disposition: .required,
                    behavior: "Keep the refusal and recovery action visible."
                )
            ]
    }

    private func accessibilityRequirements() -> [WorkflowDesignAccessibilityRequirement] {
        WorkflowDesignAccessibilityAspect.allCases.map {
            WorkflowDesignAccessibilityRequirement(
                aspect: $0,
                requirement: "The journey remains operable with \($0.rawValue).",
                measurement: "Run the \($0.rawValue) acceptance check."
            )
        }
    }

    private func designEvidenceRequirements() -> [WorkflowDesignEvidenceRequirement] {
        [
                WorkflowDesignEvidenceRequirement(
                    id: "ux-runtime",
                    dimension: .userExperience,
                    statement: "Review the executed journey.",
                    acceptedEvidenceKinds: ["runtime-capture"]
                ),
                WorkflowDesignEvidenceRequirement(
                    id: "accessibility-runtime",
                    dimension: .accessibility,
                    statement: "Review keyboard, focus and VoiceOver.",
                    acceptedEvidenceKinds: ["accessibility-audit"]
                ),
                WorkflowDesignEvidenceRequirement(
                    id: "native-runtime",
                    dimension: .platform,
                    statement: "Review the native macOS behavior.",
                    acceptedEvidenceKinds: ["macos-test-result"]
                )
            ]
    }

    private func validRubric() -> WorkflowReviewRubric {
        WorkflowReviewRubric(
            revision: 1,
            id: "design-review",
            criteria: [
                criterion("fidelity", .productFidelity, ["decision"]),
                criterion("ux", .userExperience, ["runtime-capture"]),
                criterion("accessibility", .accessibility, ["accessibility-audit"]),
                criterion("platform", .platform, ["macos-test-result"])
            ]
        )
    }

    private func criterion(
        _ id: String,
        _ dimension: WorkflowReviewDimension,
        _ evidence: [String]
    ) -> WorkflowReviewCriterion {
        WorkflowReviewCriterion(
            id: id,
            dimension: dimension,
            statement: "Review \(id).",
            blocking: true,
            acceptedEvidenceKinds: evidence
        )
    }

    private func workContract(
        design: WorkflowDesignContract,
        rubric: WorkflowReviewRubric?
    ) -> WorkflowWorkContract {
        WorkflowWorkContract(
            revision: 1,
            objective: "Ship the reviewed plan inspector journey.",
            approvedProductReference: "decision:design",
            requirements: [WorkflowRequirement(
                id: "R1",
                statement: "Show review evidence.",
                acceptanceCriteria: ["The executed journey is inspectable."]
            )],
            allowedChangePaths: ["Throttle/"],
            mustPreserve: ["Existing plan data"],
            exclusions: [],
            platforms: [.macOS],
            baseRevision: String(repeating: "a", count: 40),
            inputs: [],
            permissionRequirements: [],
            budget: WorkflowBudgetContract(),
            reviewRubric: rubric,
            design: design
        )
    }
}
