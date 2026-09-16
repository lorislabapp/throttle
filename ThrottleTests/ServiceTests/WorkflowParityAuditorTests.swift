import Foundation
import Testing
@testable import Throttle

@Suite("Workflow product platform parity")
struct WorkflowParityAuditorTests {
    @Test("required platform gaps block the product release")
    func missingRequiredTrackBlocks() {
        var input = baseInput()
        input.obligations[1].state = .missing
        input.obligations[1].evidenceRefs = []
        let result = WorkflowParityAuditor.evaluate(input)
        #expect(!result.releaseReady)
        #expect(result.unresolvedObligations == ["offline@android-phone"])
        #expect(result.coverage == 0.5)
    }

    @Test("an intentional difference needs two owners, evidence, and a future review")
    func governedDifferenceIsAcceptedUntilReview() {
        let now = Date(timeIntervalSince1970: 1_000)
        var input = baseInput()
        input.obligations[1].state = .intentionalDifference
        input.obligations[1].evidenceRefs = []
        input.differences = [WorkflowDifferenceDecision(
            id: "diff-1",
            featureID: "offline",
            trackID: "android-phone",
            category: "platform_capability",
            rationale: "The platform adapter is unavailable in this product train.",
            equivalentOutcome: "server queue",
            productApprovedBy: "product:owner",
            platformApprovedBy: "android:owner",
            evidenceRefs: ["decision://diff-1"],
            reviewAt: now.addingTimeInterval(100)
        )]
        let accepted = WorkflowParityAuditor.evaluate(input, now: now)
        #expect(accepted.releaseReady)
        #expect(accepted.acceptedDifferences == ["offline@android-phone"])

        let expired = WorkflowParityAuditor.evaluate(input, now: now.addingTimeInterval(200))
        #expect(!expired.releaseReady)
        #expect(expired.expiredDifferenceIDs == ["diff-1"])
    }

    @Test("optional and experimental tracks do not inflate required coverage")
    func optionalTracksStaySeparate() {
        var input = baseInput()
        input.obligations.append(WorkflowFeatureObligation(
            featureID: "spatial-overview",
            trackID: "vision",
            requirement: .optional,
            parityPolicy: .none,
            state: .missing,
            evidenceRefs: []
        ))
        let result = WorkflowParityAuditor.evaluate(input)
        #expect(result.releaseReady)
        #expect(result.totalRequired == 2)
        #expect(result.coverage == 1)
    }

    private func baseInput() -> WorkflowParityAuditInput {
        WorkflowParityAuditInput(
            productContractDigest: String(repeating: "a", count: 64),
            tracks: [
                WorkflowPlatformTrack(id: "mac", platform: .macOS, supportTier: .primary),
                WorkflowPlatformTrack(id: "android-phone", platform: .android, supportTier: .primary),
                WorkflowPlatformTrack(id: "vision", platform: .visionOS, supportTier: .experimental)
            ],
            obligations: [
                WorkflowFeatureObligation(
                    featureID: "offline",
                    trackID: "mac",
                    requirement: .required,
                    parityPolicy: .nativeEquivalent,
                    state: .verified,
                    evidenceRefs: ["test://mac-offline"]
                ),
                WorkflowFeatureObligation(
                    featureID: "offline",
                    trackID: "android-phone",
                    requirement: .required,
                    parityPolicy: .nativeEquivalent,
                    state: .verified,
                    evidenceRefs: ["test://android-offline"]
                )
            ],
            differences: []
        )
    }
}
