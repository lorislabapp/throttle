import Foundation
import ResearchVaultModel
import Testing
@testable import Throttle

@Suite("Research Vault Workbench projections")
struct ResearchVaultWorkbenchProjectionTests {
    @Test("preserves claim status and exposes revisions with impacted claims")
    func projections() throws {
        let first = try receipt(hash: String(repeating: "a", count: 64), day: 0, status: .verified)
        let second = try receipt(hash: String(repeating: "b", count: 64), day: 1, status: .contradicted)

        let claims = ResearchVaultWorkbenchProjection.claims(receipts: [first, second])
        #expect(claims.map(\.status) == [.contradicted, .open, .verified, .open])
        let revisions = ResearchVaultWorkbenchProjection.revisions(receipts: [first, second])
        #expect(revisions.count == 1)
        #expect(revisions[0].versions.count == 2)
        #expect(revisions[0].impactedClaims.count == 2)
        #expect(ResearchVaultWorkbenchProjection.taxonomyAudit(
            receipts: [first, second]
        ).orphanEvidenceReferences == 0)
    }

    @Test("saved views persist as filters without copying receipts")
    func savedViews() throws {
        let suite = "ResearchVaultSavedViewTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let view = ResearchVaultSavedView(
            name: "Contradictions", query: "transport", projectKey: "throttle",
            evidenceStatus: .contradicted
        )
        try ResearchVaultSavedViewStore.save([view], defaults: defaults)
        #expect(ResearchVaultSavedViewStore.load(defaults: defaults) == [view])
    }

    @Test("reasoning relation selectors include only reviewed evidence claims")
    @MainActor
    func reasoningSelectors() throws {
        let verified = try receipt(
            hash: String(repeating: "c", count: 64), day: 2, status: .verified
        )
        let open = try receipt(
            hash: String(repeating: "d", count: 64), day: 3, status: .open
        )
        let model = ResearchVaultWorkbenchModel()
        model.approvedReceipts = [open, verified]

        #expect(model.reasoningClaimReferences.count == 1)
        let reference = try #require(model.reasoningClaimReferences.first)
        #expect(reference.title == "Use TLS")
        #expect(reference.reference.receiptID == verified.receiptID)
    }

    private func receipt(
        hash: String,
        day: TimeInterval,
        status: ResearchEvidenceStatus
    ) throws -> ResearchReceipt {
        let source = ResearchSource(
            id: "source-\(Int(day))", kind: .repository, locator: "/repo/decision.md",
            observedAt: Date(timeIntervalSince1970: day * 86_400), sha256: hash
        )
        return try ResearchReceipt.seal(
            sessionID: "session", agentID: "agent", projectKey: "throttle",
            question: "Transport decision",
            findings: [.init(claim: "Use TLS", status: status, evidenceIDs: [source.id])],
            sources: [source], openQuestions: ["Which certificate?"],
            sensitivity: .internal, createdAt: source.observedAt
        )
    }
}
