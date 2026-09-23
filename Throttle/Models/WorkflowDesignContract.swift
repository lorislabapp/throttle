import CryptoKit
import Foundation

enum WorkflowDesignStateKind: String, Codable, Sendable, CaseIterable {
    case loading
    case ready
    case empty
    case error
}

enum WorkflowDesignStateDisposition: String, Codable, Sendable {
    case required
    case notApplicable
}

enum WorkflowDesignAccessibilityAspect: String, Codable, Sendable, CaseIterable {
    case keyboard
    case focus
    case voiceOver
}

enum WorkflowDesignToolAvailability: String, Codable, Sendable {
    case verified
    case unavailable
}

struct WorkflowDesignJourneyStep: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var action: String
    var expectedResult: String
}

struct WorkflowDesignState: Codable, Sendable, Equatable, Identifiable {
    var kind: WorkflowDesignStateKind
    var disposition: WorkflowDesignStateDisposition
    var behavior: String?
    var notApplicableReason: String?

    var id: WorkflowDesignStateKind { kind }
}

struct WorkflowDesignAccessibilityRequirement: Codable, Sendable, Equatable, Identifiable {
    var aspect: WorkflowDesignAccessibilityAspect
    var requirement: String
    var measurement: String

    var id: WorkflowDesignAccessibilityAspect { aspect }
}

struct WorkflowDesignPlatformAdaptation: Codable, Sendable, Equatable, Identifiable {
    var platform: WorkflowPlatform
    var behavior: String

    var id: WorkflowPlatform { platform }
}

struct WorkflowDesignEvidenceRequirement: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var dimension: WorkflowReviewDimension
    var statement: String
    var acceptedEvidenceKinds: [String]
}

struct WorkflowDesignToolStatus: Codable, Sendable, Equatable {
    var tool: String
    var availability: WorkflowDesignToolAvailability
    var evidenceRef: String?
    var unavailableReason: String?

    var isValid: Bool {
        guard nonempty(tool) else { return false }
        switch availability {
        case .verified:
            return nonempty(evidenceRef ?? "") && unavailableReason == nil
        case .unavailable:
            return evidenceRef == nil && nonempty(unavailableReason ?? "")
        }
    }

    private func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A versioned contract for one executed product journey. It records every
/// observable state and the evidence needed to review the running native UI;
/// a mockup or unavailable design integration cannot satisfy those proofs.
struct WorkflowDesignContract: Codable, Sendable, Equatable {
    var schemaVersion = 1
    var revision: Int
    var id: String
    var goal: String
    var entryPoint: String
    var steps: [WorkflowDesignJourneyStep]
    var states: [WorkflowDesignState]
    var components: [String]
    var copyRequirements: [String]
    var accessibility: [WorkflowDesignAccessibilityRequirement]
    var platformAdaptations: [WorkflowDesignPlatformAdaptation]
    var evidenceRequirements: [WorkflowDesignEvidenceRequirement]
    var designTool: WorkflowDesignToolStatus

    var digest: String? {
        guard isValid, let data = try? Self.encoder.encode(self) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var isValid: Bool {
        let stateKinds = Set(states.map(\.kind))
        let accessibilityAspects = Set(accessibility.map(\.aspect))
        return schemaVersion == 1
            && revision > 0
            && nonempty(id)
            && nonempty(goal)
            && nonempty(entryPoint)
            && !steps.isEmpty
            && Set(steps.map(\.id)).count == steps.count
            && steps.allSatisfy(validStep)
            && stateKinds == Set(WorkflowDesignStateKind.allCases)
            && states.count == stateKinds.count
            && states.allSatisfy(validState)
            && !components.isEmpty
            && components.allSatisfy(nonempty)
            && !copyRequirements.isEmpty
            && copyRequirements.allSatisfy(nonempty)
            && accessibilityAspects == Set(WorkflowDesignAccessibilityAspect.allCases)
            && accessibility.count == accessibilityAspects.count
            && accessibility.allSatisfy(validAccessibility)
            && !platformAdaptations.isEmpty
            && Set(platformAdaptations.map(\.platform)).count == platformAdaptations.count
            && platformAdaptations.allSatisfy { nonempty($0.behavior) }
            && validEvidenceRequirements
            && designTool.isValid
    }

    private var validEvidenceRequirements: Bool {
        let required: Set<WorkflowReviewDimension> = [
            .userExperience, .accessibility, .platform
        ]
        return !evidenceRequirements.isEmpty
            && Set(evidenceRequirements.map(\.id)).count == evidenceRequirements.count
            && required.isSubset(of: Set(evidenceRequirements.map(\.dimension)))
            && evidenceRequirements.allSatisfy {
                nonempty($0.id)
                    && nonempty($0.statement)
                    && !$0.acceptedEvidenceKinds.isEmpty
                    && $0.acceptedEvidenceKinds.allSatisfy(nonempty)
            }
    }

    private func validStep(_ step: WorkflowDesignJourneyStep) -> Bool {
        nonempty(step.id) && nonempty(step.action) && nonempty(step.expectedResult)
    }

    private func validState(_ state: WorkflowDesignState) -> Bool {
        if state.kind == .ready, state.disposition != .required { return false }
        switch state.disposition {
        case .required:
            return nonempty(state.behavior ?? "") && state.notApplicableReason == nil
        case .notApplicable:
            return state.behavior == nil && nonempty(state.notApplicableReason ?? "")
        }
    }

    private func validAccessibility(
        _ requirement: WorkflowDesignAccessibilityRequirement
    ) -> Bool {
        nonempty(requirement.requirement) && nonempty(requirement.measurement)
    }

    private func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
