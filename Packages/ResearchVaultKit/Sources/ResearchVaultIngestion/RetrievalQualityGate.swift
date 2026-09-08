import CryptoKit
import Foundation
import ResearchVaultIPCModel

public struct RetrievalSystemEvidence: Equatable, Sendable {
    public let recallAtK: Double
    public let reciprocalRank: Double
    public let ndcgAtK: Double
    public let abstentionAccuracy: Double
    public let citationPrecision: Double
    public let claimCoverage: Double
    public let latencyP95MS: Double
    public let peakMemoryBytes: Int
    public let energyImpact: Double

    public init(
        recallAtK: Double,
        reciprocalRank: Double,
        ndcgAtK: Double,
        abstentionAccuracy: Double,
        citationPrecision: Double,
        claimCoverage: Double,
        latencyP95MS: Double,
        peakMemoryBytes: Int,
        energyImpact: Double
    ) {
        self.recallAtK = recallAtK
        self.reciprocalRank = reciprocalRank
        self.ndcgAtK = ndcgAtK
        self.abstentionAccuracy = abstentionAccuracy
        self.citationPrecision = citationPrecision
        self.claimCoverage = claimCoverage
        self.latencyP95MS = latencyP95MS
        self.peakMemoryBytes = peakMemoryBytes
        self.energyImpact = energyImpact
    }
}

public struct RetrievalPairedOutcome: Equatable, Sendable {
    public let baselineScore: Double
    public let challengerScore: Double

    public init(baselineScore: Double, challengerScore: Double) {
        self.baselineScore = baselineScore
        self.challengerScore = challengerScore
    }
}

public struct RetrievalPromotionDecision: Equatable, Sendable {
    public let promoted: Bool
    public let reasons: [String]
    public let pairedWins: Int
    public let pairedLosses: Int
    public let twoSidedSignTestPValue: Double
}

public enum RetrievalPromotionEvaluator {
    public static func evaluate(
        baseline: RetrievalSystemEvidence,
        challenger: RetrievalSystemEvidence,
        paired: [RetrievalPairedOutcome],
        maximumLatencyP95MS: Double = 250,
        maximumPeakMemoryBytes: Int,
        maximumEnergyImpact: Double
    ) -> RetrievalPromotionDecision {
        let wins = paired.count { $0.challengerScore > $0.baselineScore }
        let losses = paired.count { $0.challengerScore < $0.baselineScore }
        let pValue = signTestPValue(wins: wins, losses: losses)
        var reasons: [String] = []
        if !valid(baseline) || !valid(challenger)
            || paired.contains(where: { !unitScore($0.baselineScore) || !unitScore($0.challengerScore) })
            || !maximumLatencyP95MS.isFinite || maximumLatencyP95MS < 0
            || maximumPeakMemoryBytes < 0
            || !maximumEnergyImpact.isFinite || maximumEnergyImpact < 0 {
            reasons.append("invalid_evidence_or_budget")
        }
        let violations: [(Bool, String)] = [
            (challenger.recallAtK < baseline.recallAtK + 0.02, "recall_gain_below_0.02"),
            (challenger.reciprocalRank < baseline.reciprocalRank, "mrr_regression"),
            (challenger.ndcgAtK < baseline.ndcgAtK, "ndcg_regression"),
            (challenger.abstentionAccuracy < 0.99, "abstention_below_0.99"),
            (challenger.citationPrecision < 0.99, "citation_precision_below_0.99"),
            (challenger.claimCoverage < 1, "claim_coverage_below_1.0"),
            (challenger.latencyP95MS > maximumLatencyP95MS, "latency_budget_exceeded"),
            (challenger.peakMemoryBytes > maximumPeakMemoryBytes, "memory_budget_exceeded"),
            (challenger.energyImpact > maximumEnergyImpact, "energy_budget_exceeded"),
            (wins + losses < 20, "insufficient_paired_cases"),
            (pValue > 0.05 || wins <= losses, "paired_gain_not_significant")
        ]
        reasons += violations.compactMap { $0.0 ? $0.1 : nil }
        return RetrievalPromotionDecision(
            promoted: reasons.isEmpty,
            reasons: reasons,
            pairedWins: wins,
            pairedLosses: losses,
            twoSidedSignTestPValue: pValue
        )
    }

    private static func signTestPValue(wins: Int, losses: Int) -> Double {
        let count = wins + losses
        guard count > 0 else { return 1 }
        let tail = min(wins, losses)
        // Start at the largest term in the tail in log space. Starting at 2^-n
        // underflows for large samples and can manufacture significance.
        let logProbability = lgamma(Double(count + 1)) - lgamma(Double(tail + 1))
            - lgamma(Double(count - tail + 1)) - Double(count) * log(2)
        var probability = exp(logProbability)
        var sum = probability
        if tail > 0 {
            for value in stride(from: tail, through: 1, by: -1) {
                probability *= Double(value) / Double(count - value + 1)
                sum += probability
            }
        }
        return min(1, 2 * sum)
    }

    private static func unitScore(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    private static func valid(_ value: RetrievalSystemEvidence) -> Bool {
        [value.recallAtK, value.reciprocalRank, value.ndcgAtK,
         value.abstentionAccuracy, value.citationPrecision, value.claimCoverage].allSatisfy(unitScore)
            && value.latencyP95MS.isFinite && value.latencyP95MS >= 0
            && value.peakMemoryBytes >= 0
            && value.energyImpact.isFinite && value.energyImpact >= 0
    }
}

public struct ResearchClaimEvaluation: Equatable, Sendable {
    public let expectedEvidenceIDs: Set<String>
    public let citedEvidenceIDs: Set<String>

    public init(expectedEvidenceIDs: Set<String>, citedEvidenceIDs: Set<String>) {
        self.expectedEvidenceIDs = expectedEvidenceIDs
        self.citedEvidenceIDs = citedEvidenceIDs
    }
}

public struct ResearchClaimMetrics: Equatable, Sendable {
    public let claimCoverage: Double
    public let citationPrecision: Double
}

public enum ResearchClaimEvaluator {
    public static func evaluate(_ claims: [ResearchClaimEvaluation]) -> ResearchClaimMetrics {
        guard !claims.isEmpty else { return .init(claimCoverage: 0, citationPrecision: 0) }
        let covered = claims.count { !$0.citedEvidenceIDs.isDisjoint(with: $0.expectedEvidenceIDs) }
        let cited = claims.reduce(0) { $0 + $1.citedEvidenceIDs.count }
        let correct = claims.reduce(0) { $0 + $1.citedEvidenceIDs.intersection($1.expectedEvidenceIDs).count }
        return ResearchClaimMetrics(
            claimCoverage: Double(covered) / Double(claims.count),
            citationPrecision: cited == 0 ? 0 : Double(correct) / Double(cited)
        )
    }
}

public struct ResearchCitationVerification: Equatable, Sendable {
    public let valid: Bool
    public let invalidDocumentIDs: [String]
}

public enum ResearchCitationVerifier {
    public static func verify(_ context: ResearchVaultContextBundle) -> ResearchCitationVerification {
        let invalid = context.items.compactMap { item -> String? in
            let citation = item.citation
            let excerptHash = SHA256.hash(data: Data(item.excerpt.utf8))
                .map { String(format: "%02x", $0) }.joined()
            guard citation.schemaVersion == ResearchVaultCitation.currentSchemaVersion,
                  citation.plaintextSHA256.count == 64,
                  citation.excerptSHA256 == excerptHash,
                  !citation.locator.isEmpty,
                  citation.locator.hasSuffix("#chunk-" + String(citation.chunkOrdinal)) else {
                return citation.documentID
            }
            if let receipt = citation.receiptProvenance {
                guard UUID(uuidString: receipt.receiptID) != nil,
                      citation.documentID == "receipt:" + receipt.receiptID,
                      citation.libraryPath == "vault-receipt/" + receipt.receiptID,
                      citation.chunkOrdinal == receipt.findingIndex,
                      receipt.findingIndex >= 0,
                      receipt.sealedContentHash.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
                      citation.origins == receipt.sources.map(\.locator) else { return citation.documentID }
            }
            return nil
        }
        return ResearchCitationVerification(valid: invalid.isEmpty, invalidDocumentIDs: invalid)
    }
}
