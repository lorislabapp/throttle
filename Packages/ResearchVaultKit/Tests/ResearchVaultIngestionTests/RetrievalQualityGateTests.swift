import CryptoKit
import Foundation
import ResearchVaultIPCModel
import ResearchVaultIngestion
import ResearchVaultModel
import Testing

@Suite("Retrieval quality gate")
struct RetrievalQualityGateTests {
    @Test("invalid measurements cannot authorize promotion")
    func rejectsInvalidEvidence() {
        for value in [Double.nan, .infinity, -.infinity, -0.1, 1.1] {
            let decision = RetrievalPromotionEvaluator.evaluate(
                baseline: evidence(recall: 0.90), challenger: evidence(recall: value),
                paired: Array(repeating: .init(baselineScore: 0, challengerScore: 1), count: 20),
                maximumPeakMemoryBytes: 100, maximumEnergyImpact: 1
            )
            #expect(!decision.promoted)
            #expect(decision.reasons.contains("invalid_evidence_or_budget"))
        }
    }

    @Test("large almost-balanced samples do not manufacture significance through underflow")
    func largeSample() {
        let paired = Array(repeating: RetrievalPairedOutcome(baselineScore: 0, challengerScore: 1), count: 601)
            + Array(repeating: RetrievalPairedOutcome(baselineScore: 1, challengerScore: 0), count: 599)
        let decision = RetrievalPromotionEvaluator.evaluate(
            baseline: evidence(recall: 0.90), challenger: evidence(recall: 0.93),
            paired: paired, maximumPeakMemoryBytes: 100, maximumEnergyImpact: 1
        )
        #expect(!decision.promoted)
        #expect(decision.twoSidedSignTestPValue > 0.9)
    }

    @Test("no claims is unmeasured, not perfect quality")
    func noClaims() {
        #expect(ResearchClaimEvaluator.evaluate([]).claimCoverage == 0)
        #expect(ResearchClaimEvaluator.evaluate([]).citationPrecision == 0)
    }

    @Test("does not promote a small or insignificant challenger")
    func conservativePromotion() {
        let baseline = evidence(recall: 0.90)
        let challenger = evidence(recall: 0.93)
        let decision = RetrievalPromotionEvaluator.evaluate(
            baseline: baseline,
            challenger: challenger,
            paired: Array(repeating: .init(baselineScore: 0, challengerScore: 1), count: 8),
            maximumPeakMemoryBytes: 100,
            maximumEnergyImpact: 1
        )
        #expect(!decision.promoted)
        #expect(decision.reasons.contains("insufficient_paired_cases"))
    }

    @Test("promotes only a significant gain inside every product budget")
    func promotesMeasuredGain() {
        let decision = RetrievalPromotionEvaluator.evaluate(
            baseline: evidence(recall: 0.90),
            challenger: evidence(recall: 0.93),
            paired: Array(repeating: .init(baselineScore: 0, challengerScore: 1), count: 20),
            maximumPeakMemoryBytes: 100,
            maximumEnergyImpact: 1
        )
        #expect(decision.promoted)
        #expect(decision.twoSidedSignTestPValue < 0.05)
    }

    @Test("measures claim coverage and rejects a tampered excerpt citation")
    func claimsAndCitations() {
        let metrics = ResearchClaimEvaluator.evaluate([
            .init(expectedEvidenceIDs: ["S1"], citedEvidenceIDs: ["S1"]),
            .init(expectedEvidenceIDs: ["S2"], citedEvidenceIDs: ["S9"]),
        ])
        #expect(metrics.claimCoverage == 0.5)
        #expect(metrics.citationPrecision == 0.5)

        let excerpt = "verified excerpt"
        let hash = SHA256.hash(data: Data(excerpt.utf8)).map { String(format: "%02x", $0) }.joined()
        let citation = ResearchVaultCitation(
            documentID: "doc", title: "Title", libraryPath: "library/doc.md", origins: ["/source"],
            plaintextSHA256: String(repeating: "a", count: 64), chunkOrdinal: 2,
            locator: "library/doc.md#chunk-2", excerptSHA256: hash,
            observedAt: Date(), sourceModifiedAt: nil, evidenceStatus: .verified,
            indexGeneration: "fts5-bm25-v1:1"
        )
        let valid = ResearchVaultContextBundle(
            query: "q", projectKeys: ["throttle"], maximumSensitivity: .internal,
            items: [.init(citation: citation, heading: nil, excerpt: excerpt, score: 1)], truncated: false
        )
        #expect(ResearchCitationVerifier.verify(valid).valid)
        let tampered = ResearchVaultContextBundle(
            query: "q", projectKeys: ["throttle"], maximumSensitivity: .internal,
            items: [.init(citation: citation, heading: nil, excerpt: "tampered", score: 1)], truncated: false
        )
        #expect(!ResearchCitationVerifier.verify(tampered).valid)
    }

    private func evidence(recall: Double) -> RetrievalSystemEvidence {
        RetrievalSystemEvidence(
            recallAtK: recall, reciprocalRank: 0.9, ndcgAtK: 0.9,
            abstentionAccuracy: 1, citationPrecision: 1, claimCoverage: 1,
            latencyP95MS: 100, peakMemoryBytes: 90, energyImpact: 0.9
        )
    }
}
