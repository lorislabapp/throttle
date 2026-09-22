import Testing
@testable import Throttle

@Suite("Workflow dependency intelligence")
struct WorkflowDependencyEvaluatorTests {
    @Test("a high score cannot compensate for a failed hard gate")
    func hardGateOverridesScore() {
        var assessment = completeAssessment()
        assessment.hardGates = assessment.hardGates.map {
            var gate = $0
            if gate.gate == .licensePolicy { gate.outcome = .failed }
            return gate
        }
        let result = WorkflowDependencyEvaluator.evaluate(assessment)
        #expect(result.score == 100)
        #expect(result.verdict == .ineligible)
        #expect(result.blockers == ["hard_gate_failed:licensePolicy"])
    }

    @Test("unknown evidence stays unknown and contributes no coverage")
    func unknownIsNotAverage() {
        var assessment = completeAssessment()
        assessment.dimensions = assessment.dimensions.map {
            guard $0.dimension == .security else { return $0 }
            return WorkflowDependencyDimensionAssessment(
                dimension: .security,
                grade: nil,
                evidenceRefs: []
            )
        }
        let result = WorkflowDependencyEvaluator.evaluate(assessment)
        #expect(result.evidenceCoverage == 91)
        #expect(result.score == 91)
        #expect(result.verdict == .eligible)
    }

    @Test("adoption requires discovery across every applicable family")
    func discoveryCannotBeShortcut() {
        var assessment = completeAssessment()
        assessment.searchedSourceFamilies = [.nativeAPI]
        assessment.distinctCandidateCount = 1
        assessment.soleViableCandidateEvidence = nil
        let result = WorkflowDependencyEvaluator.evaluate(assessment)
        #expect(result.verdict == .needsEvidence)
        #expect(result.blockers.contains("discovery_incomplete"))
        #expect(result.blockers.contains("candidate_set_too_small"))
    }

    @Test("a fully evidenced candidate can be recommended without installing it")
    func eligibleDecisionIsAdvisory() {
        let result = WorkflowDependencyEvaluator.evaluate(completeAssessment())
        #expect(result.verdict == .eligible)
        #expect(result.score == 100)
        #expect(result.evidenceCoverage == 100)
        #expect(result.blockers.isEmpty)
    }

    private func completeAssessment() -> WorkflowDependencyAssessment {
        WorkflowDependencyAssessment(
            capabilityID: "archive.signing",
            candidateID: "candidate.example",
            candidateVersion: "1.2.3",
            candidateRevision: String(repeating: "a", count: 40),
            applicableSourceFamilies: [.nativeAPI, .swiftPackage, .commandLineTool],
            searchedSourceFamilies: [.nativeAPI, .swiftPackage, .commandLineTool],
            distinctCandidateCount: 3,
            hardGates: WorkflowDependencyGate.allCases.map {
                WorkflowDependencyGateAssessment(
                    gate: $0,
                    outcome: .passed,
                    evidenceRefs: ["receipt://\($0.rawValue)"]
                )
            },
            dimensions: WorkflowDependencyDimension.allCases.map {
                WorkflowDependencyDimensionAssessment(
                    dimension: $0,
                    grade: 5,
                    evidenceRefs: ["receipt://\($0.rawValue)"]
                )
            },
            proposedDecision: .adopt,
            decisionRationale: ["All required capabilities and hard gates are measured."]
        )
    }
}
