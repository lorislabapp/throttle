import CryptoKit
import Foundation

enum RedTeamNetworkPolicy: String, Codable, Sendable {
    case denied
}

enum WorkflowFindingSeverity: String, Codable, Sendable {
    case low
    case medium
    case high
    case critical
}

enum WorkflowFindingStatus: String, Codable, Sendable {
    case suspected
    case confirmed
    case remediationCandidate
    case retestFailed
    case retestPassed
    case integrated
    case delivered
}

struct WorkflowFindingEvidence: Codable, Sendable, Equatable, Hashable {
    var kind: String
    var ref: String
    var digest: String?

    var isValid: Bool {
        nonempty(kind)
            && nonempty(ref)
            && kind.count <= 128
            && ref.count <= 4_096
            && (digest == nil || isSHA256(digest ?? ""))
    }

    private func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

struct RedTeamCampaign: Codable, Sendable, Equatable, Identifiable {
    var schemaVersion = 1
    var id: UUID
    var targetComponent: String
    var targetRevision: String
    var targetRoot: String
    var fixtureRoot: String
    var scenarioIDs: [String]
    var networkPolicy: RedTeamNetworkPolicy
    var createdAt: Date
    var requestedBy: String

    var isValid: Bool {
        schemaVersion == 1
            && nonempty(targetComponent)
            && nonempty(targetRevision)
            && targetRoot.hasPrefix("/")
            && fixtureRoot.hasPrefix("/")
            && !scenarioIDs.isEmpty
            && scenarioIDs.allSatisfy(nonempty)
            && Set(scenarioIDs).count == scenarioIDs.count
            && networkPolicy == .denied
            && nonempty(requestedBy)
    }

    private func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct WorkflowFindingRemediation: Codable, Sendable, Equatable {
    var candidateRevision: String
    var taskID: String
    var submittedBy: String
    var submittedAt: Date
    var evidence: [WorkflowFindingEvidence]
}

struct WorkflowFindingObservation: Sendable, Equatable {
    var scenarioID: String
    var component: String
    var preconditions: [String]
    var evidence: [WorkflowFindingEvidence]
    var impact: String
    var challenger: String
    var observedAt: Date = Date()
}

struct WorkflowFindingTriage: Sendable, Equatable {
    var severity: WorkflowFindingSeverity
    var justification: String
    var analyst: String
    var triagedAt: Date = Date()
}

struct WorkflowFindingRetest: Codable, Sendable, Equatable {
    var passed: Bool
    var regressionID: String
    var testedBy: String
    var testedAt: Date
    var candidateRevision: String
    var evidence: [WorkflowFindingEvidence]
}

struct WorkflowSecurityFinding: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var campaignID: UUID
    var scenarioID: String
    var component: String
    var targetRevision: String
    var preconditions: [String]
    var evidence: [WorkflowFindingEvidence]
    var impact: String
    var status: WorkflowFindingStatus
    var discoveredBy: String
    var discoveredAt: Date
    var severity: WorkflowFindingSeverity?
    var severityJustification: String?
    var triagedBy: String?
    var triagedAt: Date?
    var remediation: WorkflowFindingRemediation?
    var retests: [WorkflowFindingRetest] = []
    var integratedRevision: String?
    var deliveredVersion: String?

    var fingerprint: String {
        let fields = [campaignID.uuidString, scenarioID, component, targetRevision]
            + preconditions.sorted()
        return SHA256.hash(data: Data(fields.joined(separator: "|").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    var isValid: Bool {
        nonempty(scenarioID)
            && nonempty(component)
            && nonempty(targetRevision)
            && !preconditions.isEmpty
            && preconditions.allSatisfy(nonempty)
            && !evidence.isEmpty
            && evidence.allSatisfy(\.isValid)
            && nonempty(impact)
            && nonempty(discoveredBy)
            && lifecycleIsValid
    }

    private var lifecycleIsValid: Bool {
        let triageIsValid = severity != nil
            && nonempty(severityJustification ?? "")
            && nonempty(triagedBy ?? "")
            && triagedAt != nil
        let remediationIsValid = remediation.map {
            nonempty($0.candidateRevision)
                && $0.candidateRevision != targetRevision
                && nonempty($0.taskID)
                && nonempty($0.submittedBy)
                && !$0.evidence.isEmpty
                && $0.evidence.allSatisfy(\.isValid)
        } ?? false
        let retestsAreValid = retests.allSatisfy {
            nonempty($0.regressionID)
                && nonempty($0.testedBy)
                && !$0.evidence.isEmpty
                && $0.evidence.allSatisfy(\.isValid)
                && $0.candidateRevision == remediation?.candidateRevision
                && $0.testedBy != remediation?.submittedBy
        }
        switch status {
        case .suspected:
            return severity == nil && severityJustification == nil
                && triagedBy == nil && triagedAt == nil && remediation == nil
                && retests.isEmpty && integratedRevision == nil && deliveredVersion == nil
        case .confirmed:
            return triageIsValid && remediation == nil && retests.isEmpty
                && integratedRevision == nil && deliveredVersion == nil
        case .remediationCandidate:
            return triageIsValid && remediationIsValid && retestsAreValid
                && retests.last?.passed != true
                && integratedRevision == nil && deliveredVersion == nil
        case .retestFailed:
            return triageIsValid && remediationIsValid && retestsAreValid
                && retests.last?.passed == false
                && integratedRevision == nil && deliveredVersion == nil
        case .retestPassed:
            return triageIsValid && remediationIsValid && retestsAreValid
                && retests.last?.passed == true
                && integratedRevision == nil && deliveredVersion == nil
        case .integrated:
            return triageIsValid && remediationIsValid && retestsAreValid
                && retests.last?.passed == true
                && integratedRevision == remediation?.candidateRevision
                && deliveredVersion == nil
        case .delivered:
            return triageIsValid && remediationIsValid && retestsAreValid
                && retests.last?.passed == true
                && integratedRevision == remediation?.candidateRevision
                && nonempty(deliveredVersion ?? "")
        }
    }

    private func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct RedTeamCampaignLedger: Codable, Sendable, Equatable {
    var schemaVersion = 1
    var revision = 0
    var campaign: RedTeamCampaign
    var findings: [WorkflowSecurityFinding] = []

    var isValid: Bool {
        schemaVersion == 1
            && revision >= 0
            && campaign.isValid
            && findings.allSatisfy { $0.campaignID == campaign.id && $0.isValid }
            && Set(findings.map(\.id)).count == findings.count
            && Set(findings.map(\.fingerprint)).count == findings.count
    }
}

enum RedTeamCampaignError: Error, Equatable {
    case unsafeCampaign
    case campaignAlreadyExists
    case missingCampaign
    case unsafeStorage
    case invalidLedger
    case unknownFinding
    case invalidTransition
    case invalidEvidence
    case correlatedRetest
    case mutationBusy
    case writeNotDurable
}
