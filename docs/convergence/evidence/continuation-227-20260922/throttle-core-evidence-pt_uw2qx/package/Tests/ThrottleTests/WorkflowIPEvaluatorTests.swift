import Foundation
import Testing
@testable import Throttle

@Suite("Workflow IP and open source policy")
struct WorkflowIPEvaluatorTests {
    @Test("an unknown rights gate blocks a high-confidence opening recommendation")
    func unknownRightsBlock() {
        var assessment = completeAssessment()
        assessment.gates = assessment.gates.map {
            var gate = $0
            if gate.gate == .rights { gate.outcome = .notVerified }
            return gate
        }
        let result = WorkflowIPEvaluator.evaluate(assessment: assessment, humanDecision: nil)
        #expect(result.verdict == .blocked)
        #expect(result.blockers == ["ip_gate_not_verified:rights"])
    }

    @Test("passing gates produce a recommendation that still awaits a human")
    func noAutomaticRelicensing() {
        let result = WorkflowIPEvaluator.evaluate(
            assessment: completeAssessment(),
            humanDecision: nil
        )
        #expect(result.verdict == .awaitingHumanDecision)
        #expect(result.blockers == ["human_decision_required"])
    }

    @Test("a decision for an older assessment cannot authorize a changed boundary")
    func staleDecisionIsRejected() throws {
        let assessment = completeAssessment()
        let decision = WorkflowIPHumanDecision(
            id: UUID(),
            assessmentDigest: String(repeating: "b", count: 64),
            decision: .approved,
            decidedBy: "user:kevin",
            decidedAt: Date()
        )
        let result = WorkflowIPEvaluator.evaluate(
            assessment: assessment,
            humanDecision: decision
        )
        #expect(result.verdict == .blocked)
        #expect(result.blockers == ["human_decision_invalid_or_stale"])
        #expect(try #require(assessment.digest) != decision.assessmentDigest)
    }

    @Test("source available is labelled accurately")
    func sourceAvailableIsNotOpenSource() {
        #expect(WorkflowIPDistributionMode.sourceAvailable.publicLabel == "Source available")
        #expect(WorkflowIPDistributionMode.fullyOpenSource.publicLabel == "Open source")
    }

    private func completeAssessment() -> WorkflowIPAssessment {
        WorkflowIPAssessment(
            componentID: "throttle-sdk",
            componentRevision: String(repeating: "a", count: 40),
            inventoryDigest: String(repeating: "c", count: 64),
            proposedMode: .fullyOpenSource,
            proposedLicenseExpression: "Apache-2.0",
            gates: WorkflowIPGate.allCases.map {
                WorkflowIPGateAssessment(
                    gate: $0,
                    outcome: .passed,
                    evidenceRefs: ["receipt://\($0.rawValue)"]
                )
            },
            rationale: ["The integration surface gains value from broad adoption."],
            reconsiderOn: ["The component absorbs proprietary routing logic."]
        )
    }
}
