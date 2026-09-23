import Foundation

/// Optional lot-7 intent pinned into the task's WorkContract. The values remain
/// advisory or declarative: no dependency, reuse, license, or release effect is
/// performed by decoding this contract.
struct WorkflowProductCycleContract: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var releaseManifest: WorkflowReleaseManifest?
    var dependencyAssessment: WorkflowDependencyAssessment?
    var technologyReuseRequest: WorkflowTechnologyReuseRequest?
    var parityAudit: WorkflowParityAuditInput?
    var ipAssessment: WorkflowIPAssessment?

    var isValid: Bool {
        let members = [
            releaseManifest != nil,
            dependencyAssessment != nil,
            technologyReuseRequest != nil,
            parityAudit != nil,
            ipAssessment != nil
        ]
        return schemaVersion == 1
            && members.contains(true)
            && (releaseManifest?.isValid ?? true)
            && (dependencyAssessment?.isValid ?? true)
            && (technologyReuseRequest?.isValid ?? true)
            && (parityAudit?.isStructurallyValid ?? true)
            && (ipAssessment?.isValid ?? true)
    }
}
