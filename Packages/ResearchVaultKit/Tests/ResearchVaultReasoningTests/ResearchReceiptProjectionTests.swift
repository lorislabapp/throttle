import Foundation
import ResearchVaultModel
import ResearchVaultReasoning
import Testing

@Suite("Approved receipt reasoning projection")
struct ResearchReceiptProjectionTests {
    @Test("approved verified findings project exact claim and support facts")
    func directProjection() throws {
        let receipt = try makeReceipt(status: .verified)
        let facts = try ResearchReceiptFactProjector().directFacts(
            from: receipt,
            reviewState: .approved
        )

        #expect(facts.map(\.predicate).sorted() == ["claim", "supports"])
        #expect(facts.allSatisfy { $0.evidence == [
            ResearchFactEvidence(receiptID: receipt.receiptID, sourceID: "source-1")
        ] })
    }

    @Test("quarantined receipts and open findings never create active facts")
    func quarantineFailsClosed() throws {
        let approved = try makeReceipt(status: .open)
        #expect(try ResearchReceiptFactProjector().directFacts(
            from: approved,
            reviewState: .approved
        ).isEmpty)

        let quarantined = try makeReceipt(status: .verified)
        #expect(throws: ResearchReceiptProjectionError.receiptNotApproved(quarantined.receiptID)) {
            try ResearchReceiptFactProjector().directFacts(
                from: quarantined,
                reviewState: .quarantined
            )
        }
    }

    @Test("typed owner promotion resolves both receipts and conserves sensitivity")
    func promotedRelation() throws {
        let first = try makeReceipt(status: .verified, sensitivity: .internal)
        let second = try makeReceipt(status: .supported, sensitivity: .confidential)
        let candidate = ResearchRelationCandidate(
            relation: .supersedes,
            subject: ResearchClaimReference(receiptID: second.receiptID, findingIndex: 0),
            object: ResearchClaimReference(receiptID: first.receiptID, findingIndex: 0)
        )

        let fact = try #require(ResearchReceiptFactProjector().promotedFacts(
            candidates: [candidate],
            approvedReceipts: [first, second]
        ).first)
        #expect(fact.predicate == "supersedes")
        #expect(fact.sensitivity == .confidential)
        #expect(Set(fact.sourceReceiptIDs) == [first.receiptID, second.receiptID])
    }

    @Test("cross-project, self and ambiguous relations fail closed")
    func hostileCandidates() throws {
        let first = try makeReceipt(status: .verified, projectKey: "throttle")
        let second = try makeReceipt(status: .verified, projectKey: "other")
        let cross = ResearchRelationCandidate(
            relation: .contradicts,
            subject: .init(receiptID: first.receiptID, findingIndex: 0),
            object: .init(receiptID: second.receiptID, findingIndex: 0)
        )
        #expect(throws: ResearchReceiptProjectionError.projectMismatch) {
            try ResearchReceiptFactProjector().promotedFacts(
                candidates: [cross], approvedReceipts: [first, second]
            )
        }

        let same = ResearchClaimReference(receiptID: first.receiptID, findingIndex: 0)
        let selfRelation = ResearchRelationCandidate(
            relation: .dependsOn,
            subject: same,
            object: same
        )
        #expect(throws: ResearchReceiptProjectionError.selfRelationForbidden(selfRelation.id)) {
            try ResearchReceiptFactProjector().promotedFacts(
                candidates: [selfRelation], approvedReceipts: [first]
            )
        }
    }

    private func makeReceipt(
        status: ResearchEvidenceStatus,
        projectKey: String = "throttle",
        sensitivity: ResearchSensitivity = .internal
    ) throws -> ResearchReceipt {
        let source = ResearchSource(
            id: "source-1",
            kind: .file,
            locator: "/tmp/fixture.md",
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sha256: String(repeating: "a", count: 64)
        )
        return try ResearchReceipt.seal(
            sessionID: "session",
            agentID: "agent",
            projectKey: projectKey,
            question: "fixture",
            findings: [ResearchFinding(
                claim: "Claim",
                status: status,
                evidenceIDs: status == .verified || status == .supported ? [source.id] : []
            )],
            sources: [source],
            sensitivity: sensitivity,
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }
}
