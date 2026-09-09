import Foundation
import ResearchVaultModel

/// What a claim rests on, resolved to the exact source it cites. A claim whose
/// evidence cannot be resolved is never shown as proof: the board reports the
/// dangling reference instead of quietly dropping it.
public struct ResearchClaimEvidence: Equatable, Sendable {
    public let receiptID: String
    public let source: ResearchSource
    /// The hash the claim was made against, when the source has since been
    /// re-observed with a different one. nil while nothing moved.
    public let supersededByHash: String?

    public var hasDrifted: Bool { supersededByHash != nil }
}

/// One finding, projected with everything a reader needs to judge it without
/// opening the receipt: its lane, its evidence, and whether that evidence still
/// says what it said.
public struct ResearchClaim: Equatable, Sendable {
    public enum Lane: String, CaseIterable, Sendable {
        case proof, hypothesis, contradiction, openQuestion, drifted
    }

    public let reference: ResearchClaimReference
    public let text: String
    public let status: ResearchEvidenceStatus
    public let lane: Lane
    public let projectKey: String
    public let sensitivity: ResearchSensitivity
    public let assertedAt: Date
    public let evidence: [ResearchClaimEvidence]
    /// Evidence ids the receipt cites that its own sources do not contain.
    public let danglingEvidenceIDs: [String]
    /// Claims this one is recorded as contradicting, by promoted relation.
    public let contradicts: [ResearchClaimReference]

    public var restsOnDriftedEvidence: Bool { evidence.contains { $0.hasDrifted } }
}

/// A question nobody has answered yet, kept beside the claims rather than
/// buried in the receipt that raised it.
public struct ResearchOpenQuestion: Equatable, Sendable {
    public let receiptID: String
    public let projectKey: String
    public let question: String
    public let askedAt: Date
}

/// The Workbench's reading of the vault: claims sorted into lanes, each one
/// still pointing at the exact source. Deterministic and read-only — it
/// promotes nothing, invents no status, and cannot be built from material a
/// human has not approved.
public struct ResearchClaimsBoard: Equatable, Sendable {
    public let claims: [ResearchClaim]
    public let openQuestions: [ResearchOpenQuestion]
    /// Approved receipts that carried no finding at all.
    public let emptyReceiptIDs: [String]

    public func claims(in lane: ResearchClaim.Lane) -> [ResearchClaim] {
        claims.filter { $0.lane == lane }
    }

    public var counts: [ResearchClaim.Lane: Int] {
        Dictionary(grouping: claims, by: \.lane).mapValues(\.count)
    }
}

public enum ResearchClaimsProjector {
    /// Builds the board from approved receipts only. Quarantined material is
    /// not evidence and never reaches a lane; passing it in is a programming
    /// error the caller filters, so it is dropped rather than shown.
    ///
    /// `latestSourceHashes` is the vault's current hash per source id: a claim
    /// made against an older hash is moved to the `drifted` lane instead of
    /// continuing to read as proof.
    public static func board(
        approvedReceipts: [ResearchReceipt],
        relations: [ResearchRelationCandidate] = [],
        latestSourceHashes: [String: String] = [:]
    ) -> ResearchClaimsBoard {
        let receipts = approvedReceipts.sorted { $0.createdAt < $1.createdAt }
        var contradictedBy: [String: [ResearchClaimReference]] = [:]
        for relation in relations where relation.relation == .contradicts {
            contradictedBy[relation.object.stableID, default: []].append(relation.subject)
            contradictedBy[relation.subject.stableID, default: []].append(relation.object)
        }

        var claims: [ResearchClaim] = []
        var questions: [ResearchOpenQuestion] = []
        var empty: [String] = []

        for receipt in receipts {
            let sources = Dictionary(uniqueKeysWithValues: receipt.sources.map { ($0.id, $0) })
            if receipt.findings.isEmpty { empty.append(receipt.receiptID) }
            for question in receipt.openQuestions {
                let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                questions.append(ResearchOpenQuestion(
                    receiptID: receipt.receiptID, projectKey: receipt.projectKey,
                    question: text, askedAt: receipt.createdAt
                ))
            }
            for (index, finding) in receipt.findings.enumerated() {
                let reference = ResearchClaimReference(receiptID: receipt.receiptID, findingIndex: index)
                var evidence: [ResearchClaimEvidence] = []
                var dangling: [String] = []
                for sourceID in finding.evidenceIDs {
                    guard let source = sources[sourceID] else { dangling.append(sourceID); continue }
                    let latest = latestSourceHashes[sourceID]
                    evidence.append(ResearchClaimEvidence(
                        receiptID: receipt.receiptID, source: source,
                        supersededByHash: (latest != nil && latest != source.sha256) ? latest : nil
                    ))
                }
                let opposed = contradictedBy[reference.stableID] ?? []
                claims.append(ResearchClaim(
                    reference: reference, text: finding.claim, status: finding.status,
                    lane: lane(for: finding, evidence: evidence, dangling: dangling, contradicted: !opposed.isEmpty),
                    projectKey: receipt.projectKey, sensitivity: receipt.sensitivity,
                    assertedAt: receipt.createdAt, evidence: evidence,
                    danglingEvidenceIDs: dangling, contradicts: opposed.sorted { $0.stableID < $1.stableID }
                ))
            }
        }
        return ResearchClaimsBoard(claims: claims, openQuestions: questions, emptyReceiptIDs: empty)
    }

    /// Lane rules, in order of precedence. A contradiction outranks everything:
    /// a reader must see the conflict before the confidence. Drifted or
    /// unresolvable evidence demotes a claim out of proof, because the thing it
    /// pointed at is not the thing that is there now.
    private static func lane(
        for finding: ResearchFinding, evidence: [ResearchClaimEvidence],
        dangling: [String], contradicted: Bool
    ) -> ResearchClaim.Lane {
        if contradicted || finding.status == .contradicted { return .contradiction }
        if finding.status == .open { return .openQuestion }
        switch finding.status {
        case .verified, .supported:
            if !dangling.isEmpty || evidence.isEmpty { return .hypothesis }
            if evidence.contains { $0.hasDrifted } { return .drifted }
            return .proof
        case .stale:
            return .drifted
        case .hypothesis:
            return .hypothesis
        case .open, .contradicted:
            return .openQuestion
        }
    }
}
