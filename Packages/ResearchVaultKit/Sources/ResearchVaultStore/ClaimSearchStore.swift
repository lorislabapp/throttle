import Foundation
import ResearchVaultModel

public struct ClaimSearchHit: Equatable, Sendable {
    public let receiptID: String
    public let projectKey: String
    public let sensitivity: ResearchSensitivity
    public let claim: String
    public let status: ResearchEvidenceStatus
    public let score: Double

    public init(
        receiptID: String,
        projectKey: String,
        sensitivity: ResearchSensitivity,
        claim: String,
        status: ResearchEvidenceStatus,
        score: Double
    ) {
        self.receiptID = receiptID
        self.projectKey = projectKey
        self.sensitivity = sensitivity
        self.claim = claim
        self.status = status
        self.score = score
    }
}

public enum ClaimSearchError: Error, Equatable, Sendable {
    case emptyQuery
}

public protocol ClaimSearchStore: Sendable {
    func searchClaims(
        query: String,
        limit: Int,
        authorization: VaultAuthorization
    ) async throws -> [ClaimSearchHit]
}

