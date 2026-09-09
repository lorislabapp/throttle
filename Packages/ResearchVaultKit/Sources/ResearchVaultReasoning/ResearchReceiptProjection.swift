import CryptoKit
import Foundation
import ResearchVaultModel

public enum ResearchRelationKind: String, Codable, CaseIterable, Sendable {
    case contradicts
    case supersedes
    case dependsOn
}

public struct ResearchClaimReference: Codable, Hashable, Sendable {
    public let receiptID: String
    public let findingIndex: Int

    public init(receiptID: String, findingIndex: Int) {
        self.receiptID = receiptID
        self.findingIndex = findingIndex
    }

    public var stableID: String { receiptID + "#finding-" + String(findingIndex) }

    /// Reads back a reference a fact argument carries. Anything that is not
    /// exactly this shape is refused rather than guessed: a receipt id may
    /// itself contain no separator, so a malformed argument is not a reference.
    public init?(stableID: String) {
        let parts = stableID.components(separatedBy: "#finding-")
        guard parts.count == 2, !parts[0].isEmpty,
              let index = Int(parts[1]), index >= 0,
              String(index) == parts[1] else { return nil }
        self.init(receiptID: parts[0], findingIndex: index)
    }
}

public struct ResearchRelationCandidate: Codable, Hashable, Sendable {
    public let id: String
    public let relation: ResearchRelationKind
    public let subject: ResearchClaimReference
    public let object: ResearchClaimReference
    public let validFrom: Date?
    public let validUntil: Date?

    public init(
        relation: ResearchRelationKind,
        subject: ResearchClaimReference,
        object: ResearchClaimReference,
        validFrom: Date? = nil,
        validUntil: Date? = nil
    ) {
        self.relation = relation
        self.subject = subject
        self.object = object
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.id = Self.makeID(
            relation: relation,
            subject: subject,
            object: object,
            validFrom: validFrom,
            validUntil: validUntil
        )
    }

    private static func makeID(
        relation: ResearchRelationKind,
        subject: ResearchClaimReference,
        object: ResearchClaimReference,
        validFrom: Date?,
        validUntil: Date?
    ) -> String {
        func instant(_ date: Date?) -> String {
            date.map { String($0.timeIntervalSince1970.bitPattern, radix: 16) } ?? "-"
        }
        let canonical = [
            relation.rawValue, subject.stableID, object.stableID,
            instant(validFrom), instant(validUntil)
        ].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public enum ResearchReceiptProjectionError: Error, Equatable, Sendable {
    case receiptNotApproved(String)
    case invalidFindingReference(ResearchClaimReference)
    case unsupportedFindingStatus(ResearchClaimReference)
    case evidenceRequired(ResearchClaimReference)
    case invalidEvidence(receiptID: String, sourceID: String)
    case projectMismatch
    case selfRelationForbidden(String)
    case invalidValidityInterval(String)
    case tooManyCandidates
}

/// Deterministic projection only. It never parses relation syntax from source
/// text and never promotes model output. Receipt approval is required for the
/// direct claim/support facts; cross-claim candidates need a separate owner
/// promotion call at the gateway boundary.
public struct ResearchReceiptFactProjector: Sendable {
    public static let maximumCandidates = 512

    public init() {}

    public func directFacts(
        from receipt: ResearchReceipt,
        reviewState: ResearchReviewState
    ) throws -> [ResearchFact] {
        guard reviewState == .approved else {
            throw ResearchReceiptProjectionError.receiptNotApproved(receipt.receiptID)
        }
        try ResearchReceiptValidator.validate(receipt)
        let sources = Dictionary(uniqueKeysWithValues: receipt.sources.map { ($0.id, $0) })
        var facts: [ResearchFact] = []
        for (index, finding) in receipt.findings.enumerated() {
            let reference = ResearchClaimReference(
                receiptID: receipt.receiptID,
                findingIndex: index
            )
            guard finding.status == .verified || finding.status == .supported else { continue }
            guard !finding.evidenceIDs.isEmpty else {
                throw ResearchReceiptProjectionError.evidenceRequired(reference)
            }
            let evidence = try finding.evidenceIDs.map { sourceID -> ResearchFactEvidence in
                guard sources[sourceID] != nil else {
                    throw ResearchReceiptProjectionError.invalidEvidence(
                        receiptID: receipt.receiptID,
                        sourceID: sourceID
                    )
                }
                return ResearchFactEvidence(receiptID: receipt.receiptID, sourceID: sourceID)
            }
            facts.append(ResearchFact(
                predicate: "claim",
                arguments: [reference.stableID],
                projectKey: receipt.projectKey,
                sensitivity: receipt.sensitivity,
                assertedAt: receipt.createdAt,
                evidence: evidence
            ))
            for item in evidence {
                facts.append(ResearchFact(
                    predicate: "supports",
                    arguments: [reference.stableID, item.receiptID + "#source-" + item.sourceID],
                    projectKey: receipt.projectKey,
                    sensitivity: receipt.sensitivity,
                    assertedAt: receipt.createdAt,
                    evidence: [item]
                ))
            }
        }
        return Array(Set(facts)).sorted { $0.id < $1.id }
    }

    public func promotedFacts(
        candidates: [ResearchRelationCandidate],
        approvedReceipts: [ResearchReceipt]
    ) throws -> [ResearchFact] {
        guard candidates.count <= Self.maximumCandidates else {
            throw ResearchReceiptProjectionError.tooManyCandidates
        }
        let receipts = Dictionary(uniqueKeysWithValues: approvedReceipts.map { ($0.receiptID, $0) })
        return try candidates.sorted { $0.id < $1.id }.map { candidate in
            guard candidate.subject != candidate.object else {
                throw ResearchReceiptProjectionError.selfRelationForbidden(candidate.id)
            }
            guard Self.hasValidInterval(from: candidate.validFrom, until: candidate.validUntil) else {
                throw ResearchReceiptProjectionError.invalidValidityInterval(candidate.id)
            }
            let subject = try resolve(candidate.subject, receipts: receipts)
            let object = try resolve(candidate.object, receipts: receipts)
            guard subject.receipt.projectKey == object.receipt.projectKey else {
                throw ResearchReceiptProjectionError.projectMismatch
            }
            let evidence = (subject.evidence + object.evidence)
                .reduce(into: Set<ResearchFactEvidence>()) { $0.insert($1) }
                .sorted()
            return ResearchFact(
                predicate: candidate.relation.rawValue,
                arguments: [candidate.subject.stableID, candidate.object.stableID],
                projectKey: subject.receipt.projectKey,
                sensitivity: max(subject.receipt.sensitivity, object.receipt.sensitivity),
                validFrom: candidate.validFrom,
                validUntil: candidate.validUntil,
                assertedAt: max(subject.receipt.createdAt, object.receipt.createdAt),
                evidence: evidence
            )
        }
    }

    private static func hasValidInterval(from: Date?, until: Date?) -> Bool {
        guard let from, let until else { return true }
        return from <= until
    }

    private func resolve(
        _ reference: ResearchClaimReference,
        receipts: [String: ResearchReceipt]
    ) throws -> (receipt: ResearchReceipt, evidence: [ResearchFactEvidence]) {
        guard let receipt = receipts[reference.receiptID],
              receipt.findings.indices.contains(reference.findingIndex) else {
            throw ResearchReceiptProjectionError.invalidFindingReference(reference)
        }
        let finding = receipt.findings[reference.findingIndex]
        guard finding.status == .verified || finding.status == .supported else {
            throw ResearchReceiptProjectionError.unsupportedFindingStatus(reference)
        }
        guard !finding.evidenceIDs.isEmpty else {
            throw ResearchReceiptProjectionError.evidenceRequired(reference)
        }
        let sourceIDs = Set(receipt.sources.map(\.id))
        let evidence = try finding.evidenceIDs.map { sourceID -> ResearchFactEvidence in
            guard sourceIDs.contains(sourceID) else {
                throw ResearchReceiptProjectionError.invalidEvidence(
                    receiptID: receipt.receiptID,
                    sourceID: sourceID
                )
            }
            return ResearchFactEvidence(receiptID: receipt.receiptID, sourceID: sourceID)
        }
        return (receipt, evidence)
    }
}
