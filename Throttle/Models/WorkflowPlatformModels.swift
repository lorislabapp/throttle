import Foundation

enum WorkflowPlatformSupportTier: String, Codable, Sendable {
    case primary, secondary, experimental, deprecated
}

struct WorkflowPlatformTrack: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var platform: WorkflowPlatform
    var supportTier: WorkflowPlatformSupportTier
}

enum WorkflowFeatureRequirement: String, Codable, Sendable {
    case required, optional, notApplicable
}

enum WorkflowParityPolicy: String, Codable, Sendable {
    case none, semantic, strict, nativeEquivalent
}

enum WorkflowFeatureObligationState: String, Codable, Sendable {
    case verified, partial, missing, intentionalDifference, notApplicable, blocked
}

struct WorkflowFeatureObligation: Codable, Sendable, Equatable, Identifiable {
    var featureID: String
    var trackID: String
    var requirement: WorkflowFeatureRequirement
    var parityPolicy: WorkflowParityPolicy
    var state: WorkflowFeatureObligationState
    var evidenceRefs: [String]

    var id: String { featureID + "@" + trackID }
}

struct WorkflowDifferenceDecision: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var featureID: String
    var trackID: String
    var category: String
    var rationale: String
    var equivalentOutcome: String?
    var productApprovedBy: String
    var platformApprovedBy: String
    var evidenceRefs: [String]
    var reviewAt: Date

    func isValid(at now: Date) -> Bool {
        [id, featureID, trackID, category, rationale, productApprovedBy, platformApprovedBy]
            .allSatisfy(nonempty)
            && !evidenceRefs.isEmpty
            && evidenceRefs.allSatisfy(nonempty)
            && reviewAt > now
    }

    private func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct WorkflowParityAuditInput: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var productContractDigest: String
    var tracks: [WorkflowPlatformTrack]
    var obligations: [WorkflowFeatureObligation]
    var differences: [WorkflowDifferenceDecision]

    var isStructurallyValid: Bool {
        let trackIDs = tracks.map(\.id)
        let obligationIDs = obligations.map(\.id)
        let differenceIDs = differences.map(\.id)
        let knownTracks = Set(trackIDs)
        let knownObligations = Set(obligationIDs)
        return schemaVersion == 1
            && Self.isDigest(productContractDigest)
            && !tracks.isEmpty
            && trackIDs.allSatisfy(Self.nonempty)
            && Set(trackIDs).count == trackIDs.count
            && Set(obligationIDs).count == obligationIDs.count
            && obligations.allSatisfy {
                Self.nonempty($0.featureID)
                    && knownTracks.contains($0.trackID)
                    && $0.evidenceRefs.allSatisfy(Self.nonempty)
            }
            && Set(differenceIDs).count == differenceIDs.count
            && differences.allSatisfy {
                Self.nonempty($0.id)
                    && Self.nonempty($0.category)
                    && Self.nonempty($0.rationale)
                    && Self.nonempty($0.productApprovedBy)
                    && Self.nonempty($0.platformApprovedBy)
                    && knownObligations.contains($0.featureID + "@" + $0.trackID)
                    && !$0.evidenceRefs.isEmpty
                    && $0.evidenceRefs.allSatisfy(Self.nonempty)
            }
    }

    private static func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

struct WorkflowParityAuditResult: Sendable, Equatable {
    var releaseReady: Bool
    var verifiedRequired: Int
    var totalRequired: Int
    var acceptedDifferences: [String]
    var unresolvedObligations: [String]
    var expiredDifferenceIDs: [String]

    var coverage: Double? {
        totalRequired == 0 ? nil : Double(verifiedRequired) / Double(totalRequired)
    }
}

enum WorkflowParityAuditor {
    static func evaluate(
        _ input: WorkflowParityAuditInput,
        now: Date = Date()
    ) -> WorkflowParityAuditResult {
        guard input.isStructurallyValid else {
            return .init(
                releaseReady: false,
                verifiedRequired: 0,
                totalRequired: input.obligations.filter { $0.requirement == .required }.count,
                acceptedDifferences: [],
                unresolvedObligations: ["audit_input_invalid"],
                expiredDifferenceIDs: []
            )
        }
        let required = input.obligations.filter { $0.requirement == .required }
        var verified = 0
        var accepted: [String] = []
        var unresolved: [String] = []
        var expired: [String] = []
        for obligation in required {
            if obligation.state == .verified, !obligation.evidenceRefs.isEmpty {
                verified += 1
                continue
            }
            let decision = input.differences.first {
                $0.featureID == obligation.featureID && $0.trackID == obligation.trackID
            }
            if [.intentionalDifference, .notApplicable].contains(obligation.state),
               let decision {
                if decision.isValid(at: now) {
                    accepted.append(obligation.id)
                } else {
                    expired.append(decision.id)
                    unresolved.append(obligation.id)
                }
            } else {
                unresolved.append(obligation.id)
            }
        }
        return .init(
            releaseReady: unresolved.isEmpty,
            verifiedRequired: verified,
            totalRequired: required.count,
            acceptedDifferences: accepted.sorted(),
            unresolvedObligations: unresolved.sorted(),
            expiredDifferenceIDs: expired.sorted()
        )
    }

}
