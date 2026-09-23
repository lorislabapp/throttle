import CryptoKit
import Foundation

enum WorkflowReviewDimension: String, Codable, Sendable, CaseIterable {
    case productFidelity
    case correctness
    case robustness
    case maintainability
    case userExperience
    case accessibility
    case performance
    case security
    case privacy
    case platform
}

enum WorkflowReviewOutcome: String, Codable, Sendable {
    case pass
    case fail
    case notVerified
    case notApplicable
}

enum WorkflowReviewerKind: String, Codable, Sendable {
    case model
    case deterministic
    case human
}

struct WorkflowReviewCriterion: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var dimension: WorkflowReviewDimension
    var statement: String
    var blocking: Bool
    var requiresHuman: Bool = false
    var acceptedEvidenceKinds: [String]

    var isValid: Bool {
        nonempty(id)
            && nonempty(statement)
            && !acceptedEvidenceKinds.isEmpty
            && acceptedEvidenceKinds.allSatisfy(nonempty)
            && Set(acceptedEvidenceKinds).count == acceptedEvidenceKinds.count
    }

    private func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct WorkflowReviewRubric: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var revision: Int
    var id: String
    var criteria: [WorkflowReviewCriterion]

    var digest: String? {
        guard isValid, let data = try? Self.encoder.encode(self) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var isValid: Bool {
        schemaVersion == 1
            && revision > 0
            && !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !criteria.isEmpty
            && criteria.allSatisfy(\.isValid)
            && Set(criteria.map(\.id)).count == criteria.count
            && criteria.contains { $0.dimension == .productFidelity }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

struct WorkflowReviewEvidence: Codable, Sendable, Equatable, Hashable {
    var kind: String
    var ref: String
}

struct WorkflowReviewAssessment: Codable, Sendable, Equatable, Identifiable {
    var criterionID: String
    var outcome: WorkflowReviewOutcome
    var evidence: [WorkflowReviewEvidence]
    var note: String?
    var notApplicableReason: String?

    var id: String { criterionID }
}

struct WorkflowReviewReport: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var id: UUID
    var taskID: String
    var workContractDigest: String
    var rubricDigest: String
    var candidateStamp: String
    var producerRuntime: String
    var reviewerID: String
    var reviewerRuntime: String
    var reviewerKind: WorkflowReviewerKind
    var createdAt: Date
    var assessments: [WorkflowReviewAssessment]

    var digest: String? {
        guard let data = try? Self.encoder.encode(self) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

enum WorkflowReviewDecision: String, Codable, Sendable {
    case accepted
    case rejected
}

struct WorkflowReviewEvaluation: Sendable, Equatable {
    var decision: WorkflowReviewDecision
    var blockingCriterionIDs: [String]
    var nonblockingFindingIDs: [String]
}

enum WorkflowReviewError: Error, Equatable, CustomStringConvertible {
    case missingRubric
    case invalidRubric
    case invalidReport
    case staleContract
    case staleCandidate
    case producerMismatch
    case correlatedReviewer
    case humanReviewRequired
    case unknownEvidence(String)
    case evidenceKindMismatch(String)

    var description: String {
        switch self {
        case .missingRubric: return "the task has no review rubric."
        case .invalidRubric: return "the review rubric is invalid."
        case .invalidReport: return "the review report is incomplete or contradictory."
        case .staleContract: return "the review targets a different work contract."
        case .staleCandidate: return "the review targets a different or unverified candidate."
        case .producerMismatch: return "the report names the wrong producing runtime."
        case .correlatedReviewer: return "the producing runtime cannot independently review itself."
        case .humanReviewRequired: return "this rubric contains a criterion that requires human review."
        case .unknownEvidence(let ref): return "the review cites unknown evidence '\(ref)'."
        case .evidenceKindMismatch(let id):
            return "criterion '\(id)' cites an evidence kind its rubric does not accept."
        }
    }
}
