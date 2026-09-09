import Foundation
import ResearchVaultModel
import ResearchVaultReasoning
import Testing

@Suite("Claims board")
struct ResearchClaimsBoardTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func source(_ id: String, hash: Character = "a") -> ResearchSource {
        ResearchSource(id: id, kind: .file, locator: "/tmp/\(id).md",
                       observedAt: epoch, sha256: String(repeating: hash, count: 64))
    }

    private func receipt(
        _ findings: [ResearchFinding], sources: [ResearchSource],
        openQuestions: [String] = [], project: String = "throttle",
        sensitivity: ResearchSensitivity = .internal, offset: TimeInterval = 0
    ) throws -> ResearchReceipt {
        try ResearchReceipt.seal(
            sessionID: "session", agentID: "agent", projectKey: project,
            question: "fixture", findings: findings, sources: sources,
            openQuestions: openQuestions, sensitivity: sensitivity,
            createdAt: epoch.addingTimeInterval(offset)
        )
    }

    @Test("each finding lands in the lane its evidence earns, pointing at the exact source")
    func lanes() throws {
        let alpha = source("alpha")
        let receipt = try receipt([
            ResearchFinding(claim: "Proven", status: .verified, evidenceIDs: [alpha.id]),
            ResearchFinding(claim: "Likely", status: .hypothesis, evidenceIDs: []),
            ResearchFinding(claim: "Disproved", status: .contradicted, evidenceIDs: [alpha.id]),
            ResearchFinding(claim: "Unknown", status: .open, evidenceIDs: []),
            ResearchFinding(claim: "Aged", status: .stale, evidenceIDs: [alpha.id])
        ], sources: [alpha], openQuestions: ["  What about B?  ", "   "])

        let board = ResearchClaimsProjector.board(approvedReceipts: [receipt])
        #expect(board.counts == [.proof: 1, .hypothesis: 1, .contradiction: 1,
                                 .openQuestion: 1, .drifted: 1])
        let proof = try #require(board.claims(in: .proof).first)
        #expect(proof.text == "Proven")
        #expect(proof.evidence.map(\.source.locator) == ["/tmp/alpha.md"])
        #expect(proof.evidence.allSatisfy { !$0.hasDrifted })
        #expect(board.openQuestions.map(\.question) == ["What about B?"],
                "a blank question is not a question")
        #expect(board.emptyReceiptIDs.isEmpty)
    }

    @Test("a claim whose source moved is demoted out of proof, never silently kept")
    func drift() throws {
        let alpha = source("alpha")
        let receipt = try receipt(
            [ResearchFinding(claim: "Proven", status: .verified, evidenceIDs: [alpha.id])],
            sources: [alpha]
        )
        let unchanged = ResearchClaimsProjector.board(
            approvedReceipts: [receipt], latestSourceHashes: [alpha.id: alpha.sha256]
        )
        #expect(unchanged.claims(in: .proof).count == 1)

        let moved = String(repeating: "b", count: 64)
        let board = ResearchClaimsProjector.board(
            approvedReceipts: [receipt], latestSourceHashes: [alpha.id: moved]
        )
        let claim = try #require(board.claims(in: .drifted).first)
        #expect(claim.restsOnDriftedEvidence)
        #expect(claim.evidence.first?.supersededByHash == moved)
        #expect(claim.status == .verified, "the recorded status is reported, not rewritten")
        #expect(board.claims(in: .proof).isEmpty)
    }

    /// `seal` refuses a finding citing a source the receipt does not carry, so
    /// this shape can only reach the board from storage written before that
    /// rule existed. The board must name it rather than read it as proof.
    @Test("evidence the receipt cites but does not carry is named, not dropped")
    func danglingEvidence() throws {
        let alpha = source("alpha")
        let sealed = try receipt(
            [ResearchFinding(claim: "Proven", status: .verified, evidenceIDs: [alpha.id])],
            sources: [alpha]
        )
        let receipt = ResearchReceipt(
            receiptID: sealed.receiptID, sessionID: sealed.sessionID, agentID: sealed.agentID,
            projectKey: sealed.projectKey, question: sealed.question,
            findings: [ResearchFinding(claim: "Proven", status: .verified,
                                       evidenceIDs: [alpha.id, "ghost"])],
            sources: [alpha], sensitivity: sealed.sensitivity,
            createdAt: sealed.createdAt, contentHash: sealed.contentHash
        )
        let board = ResearchClaimsProjector.board(approvedReceipts: [receipt])
        let claim = try #require(board.claims(in: .hypothesis).first)
        #expect(claim.danglingEvidenceIDs == ["ghost"])
        #expect(claim.evidence.count == 1)
        #expect(board.claims(in: .proof).isEmpty, "a claim missing a cited source is not proof")
    }

    @Test("a promoted contradiction outranks confidence on both sides")
    func contradiction() throws {
        let alpha = source("alpha")
        let beta = source("beta", hash: "c")
        let first = try receipt(
            [ResearchFinding(claim: "It is A", status: .verified, evidenceIDs: [alpha.id])],
            sources: [alpha]
        )
        let second = try receipt(
            [ResearchFinding(claim: "It is B", status: .verified, evidenceIDs: [beta.id])],
            sources: [beta], offset: 10
        )
        let relation = ResearchRelationCandidate(
            relation: .contradicts,
            subject: ResearchClaimReference(receiptID: second.receiptID, findingIndex: 0),
            object: ResearchClaimReference(receiptID: first.receiptID, findingIndex: 0)
        )
        let board = ResearchClaimsProjector.board(
            approvedReceipts: [second, first], relations: [relation]
        )
        #expect(board.claims(in: .contradiction).count == 2)
        #expect(board.claims(in: .proof).isEmpty)
        let claim = try #require(board.claims(in: .contradiction).first)
        #expect(claim.contradicts.count == 1)
        #expect(board.claims.map(\.assertedAt) == [epoch, epoch.addingTimeInterval(10)],
                "claims read oldest first whatever order they arrive in")

        let unrelated = ResearchRelationCandidate(
            relation: .supersedes,
            subject: ResearchClaimReference(receiptID: second.receiptID, findingIndex: 0),
            object: ResearchClaimReference(receiptID: first.receiptID, findingIndex: 0)
        )
        #expect(ResearchClaimsProjector.board(
            approvedReceipts: [first, second], relations: [unrelated]
        ).claims(in: .proof).count == 2, "only a contradiction moves a claim")
    }

    @Test("a claim reference round-trips through its stable id and refuses anything else")
    func referenceParsing() throws {
        let reference = ResearchClaimReference(receiptID: "r-1", findingIndex: 3)
        #expect(ResearchClaimReference(stableID: reference.stableID) == reference)
        for bad in ["", "r-1", "r-1#finding-", "r-1#finding--1", "r-1#finding-01",
                    "r-1#finding-x", "#finding-0", "r-1#finding-0#finding-1"] {
            #expect(ResearchClaimReference(stableID: bad) == nil, "\(bad) is not a reference")
        }
    }

    @Test("an approved receipt with nothing in it is reported rather than hidden")
    func emptyReceipt() throws {
        let receipt = try receipt([], sources: [source("alpha")])
        let board = ResearchClaimsProjector.board(approvedReceipts: [receipt])
        #expect(board.emptyReceiptIDs == [receipt.receiptID])
        #expect(board.claims.isEmpty)
        #expect(ResearchClaimsProjector.board(approvedReceipts: []).counts.isEmpty)
    }
}
