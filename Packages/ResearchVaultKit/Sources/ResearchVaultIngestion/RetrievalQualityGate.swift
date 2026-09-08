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
        if challenger.recallAtK < baseline.recallAtK + 0.02 { reasons.append("recall_gain_below_0.02") }
        if challenger.reciprocalRank < baseline.reciprocalRank { reasons.append("mrr_regression") }
        if challenger.ndcgAtK < baseline.ndcgAtK { reasons.append("ndcg_regression") }
        if challenger.abstentionAccuracy < 0.99 { reasons.append("abstention_below_0.99") }
        if challenger.citationPrecision < 0.99 { reasons.append("citation_precision_below_0.99") }
        if challenger.claimCoverage < 1 { reasons.append("claim_coverage_below_1.0") }
        if challenger.latencyP95MS > maximumLatencyP95MS { reasons.append("latency_budget_exceeded") }
        if challenger.peakMemoryBytes > maximumPeakMemoryBytes { reasons.append("memory_budget_exceeded") }
        if challenger.energyImpact > maximumEnergyImpact { reasons.append("energy_budget_exceeded") }
        if wins + losses < 20 { reasons.append("insufficient_paired_cases") }
        if pValue > 0.05 || wins <= losses { reasons.append("paired_gain_not_significant") }
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
        var probability = pow(0.5, Double(count))
        var sum = probability
        guard tail > 0 else { return min(1, 2 * sum) }
        for value in 1 ... tail {
            probability *= Double(count - value + 1) / Double(value)
            sum += probability
        }
        return min(1, 2 * sum)
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
        guard !claims.isEmpty else { return .init(claimCoverage: 1, citationPrecision: 1) }
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
