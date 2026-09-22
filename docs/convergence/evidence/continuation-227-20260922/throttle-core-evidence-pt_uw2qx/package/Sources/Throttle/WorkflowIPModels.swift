import CryptoKit
import Foundation

enum WorkflowIPDistributionMode: String, Codable, Sendable {
    case closedSource
    case sourceAvailable
    case partialOpenSource
    case fullyOpenSource

    var publicLabel: String {
        switch self {
        case .closedSource: "Closed source"
        case .sourceAvailable: "Source available"
        case .partialOpenSource: "Partial open source"
        case .fullyOpenSource: "Open source"
        }
    }
}

enum WorkflowIPGate: String, Codable, Sendable, CaseIterable {
    case rights
    case dependencies
    case data
    case securityAndAbuse
    case maintenance
}

struct WorkflowIPGateAssessment: Codable, Sendable, Equatable {
    var gate: WorkflowIPGate
    var outcome: WorkflowGateOutcome
    var evidenceRefs: [String]

    var isValid: Bool {
        !evidenceRefs.isEmpty
            && evidenceRefs.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

struct WorkflowIPAssessment: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var componentID: String
    var componentRevision: String
    var inventoryDigest: String
    var proposedMode: WorkflowIPDistributionMode
    var proposedLicenseExpression: String?
    var gates: [WorkflowIPGateAssessment]
    var rationale: [String]
    var reconsiderOn: [String]

    var digest: String? {
        guard isValid, let data = try? Self.encoder.encode(self) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var isValid: Bool {
        let gateIDs = gates.map(\.gate)
        let licenseRequired = proposedMode != .closedSource
        return schemaVersion == 1
            && nonempty(componentID)
            && isObjectID(componentRevision)
            && isDigest(inventoryDigest)
            && (!licenseRequired || proposedLicenseExpression.map(nonempty) == true)
            && Set(gateIDs) == Set(WorkflowIPGate.allCases)
            && gateIDs.count == WorkflowIPGate.allCases.count
            && gates.allSatisfy(\.isValid)
            && !rationale.isEmpty
            && rationale.allSatisfy(nonempty)
            && !reconsiderOn.isEmpty
            && reconsiderOn.allSatisfy(nonempty)
    }

    private func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isObjectID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.allSatisfy(\.isHexDigit)
    }

    private func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

enum WorkflowIPHumanDecisionValue: String, Codable, Sendable {
    case approved, rejected
}

struct WorkflowIPHumanDecision: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var id: UUID
    var assessmentDigest: String
    var decision: WorkflowIPHumanDecisionValue
    var decidedBy: String
    var decidedAt: Date
}

enum WorkflowIPVerdict: String, Codable, Sendable {
    case blocked, awaitingHumanDecision, approvedRecommendation, rejected
}

struct WorkflowIPEvaluation: Sendable, Equatable {
    var verdict: WorkflowIPVerdict
    var blockers: [String]
}

enum WorkflowIPEvaluator {
    static func evaluate(
        assessment: WorkflowIPAssessment,
        humanDecision: WorkflowIPHumanDecision?
    ) -> WorkflowIPEvaluation {
        guard let digest = assessment.digest else {
            return .init(verdict: .blocked, blockers: ["ip_assessment_invalid"])
        }
        let failures = assessment.gates.filter { $0.outcome == .failed }.map {
            "ip_gate_failed:\($0.gate.rawValue)"
        }
        let unknowns = assessment.gates.filter { $0.outcome == .notVerified }.map {
            "ip_gate_not_verified:\($0.gate.rawValue)"
        }
        let blockers = (failures + unknowns).sorted()
        guard blockers.isEmpty else { return .init(verdict: .blocked, blockers: blockers) }
        guard let humanDecision else {
            return .init(verdict: .awaitingHumanDecision, blockers: ["human_decision_required"])
        }
        guard humanDecision.schemaVersion == 1,
              humanDecision.assessmentDigest == digest,
              !humanDecision.decidedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(verdict: .blocked, blockers: ["human_decision_invalid_or_stale"])
        }
        return humanDecision.decision == .approved
            ? .init(verdict: .approvedRecommendation, blockers: [])
            : .init(verdict: .rejected, blockers: ["human_decision_rejected"])
    }
}
