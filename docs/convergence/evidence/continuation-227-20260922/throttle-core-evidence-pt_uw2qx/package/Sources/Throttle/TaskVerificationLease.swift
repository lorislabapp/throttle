import Foundation

/// A controller's durable execution intent, not an OS permission grant.
/// The log sequence fences acknowledgements; expiry never permits blind replay.
struct TaskVerificationLease: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var id: UUID
    var fence: Int
    var owner: String
    var missionID: String?
    var inputStamp: String
    var commandDigest: String
    var expiresAt: Date

    var isValid: Bool {
        schemaVersion == 1 && fence > 0 && !owner.isEmpty && !inputStamp.isEmpty
            && expiresAt.timeIntervalSince1970.isFinite
            && commandDigest.count == 64 && commandDigest.allSatisfy { $0.isHexDigit }
    }
}

enum TaskVerificationError: Error, Equatable, CustomStringConvertible {
    case missingStore
    case processOutcomeUnknown
    case invalidRequest
    case ineligibleTask
    case unresolvedExecution(UUID)
    case staleExecution
    case recoveryEvidenceRequired

    var description: String {
        switch self {
        case .processOutcomeUnknown: return "The process result is unknown; the verification remains unresolved."
        case .missingStore: return "Verification requires the project's durable plan store."
        case .invalidRequest: return "Verification requires a command, identity and finite positive timeout."
        case .ineligibleTask: return "This task is not ready for verification."
        case .unresolvedExecution(let identity):
            return "Verification \(identity) has no observed outcome. "
                + "Confirm its processes have stopped before recording recovery; it cannot be retried automatically."
        case .staleExecution: return "This acknowledgement does not belong to the current verification."
        case .recoveryEvidenceRequired:
            return "Recovery requires an identified observer and a stopped-process evidence reference."
        }
    }
}
