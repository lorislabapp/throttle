import Foundation

enum WorkflowTechnologyKind: String, Codable, Sendable {
    case component, package, service, tool, model, knowledgeAsset
}

enum WorkflowTechnologyPrivacy: String, Codable, Sendable {
    case publicAsset, internalAsset, privateAsset, restricted
}

enum WorkflowTechnologyLifecycle: String, Codable, Sendable {
    case maintained, experimental, deprecated, unknown
}

enum WorkflowTechnologyInterface: String, Codable, Sendable {
    case swiftAPI, kotlinAPI, http, grpc, mcp, commandLine
}

struct WorkflowTechnologyCatalogEntry: Codable, Sendable, Equatable, Identifiable {
    var schemaVersion: Int = 1
    var id: String
    var kind: WorkflowTechnologyKind
    var name: String
    var sourceRevision: String
    var sourcePath: String
    var ownerProject: String
    var privacy: WorkflowTechnologyPrivacy
    var discoverableByProjects: [String]
    var reusableByProjects: [String]
    var capabilities: [String]
    var interfaces: [WorkflowTechnologyInterface]
    var lifecycle: WorkflowTechnologyLifecycle
    var evidenceRefs: [String]
    var lastSeenAt: Date

    var isValid: Bool {
        schemaVersion == 1
            && [id, name, sourcePath, ownerProject].allSatisfy(nonempty)
            && isObjectID(sourceRevision)
            && !sourcePath.hasPrefix("/")
            && !sourcePath.contains("../")
            && !capabilities.isEmpty
            && capabilities.allSatisfy(nonempty)
            && Set(capabilities).count == capabilities.count
            && !interfaces.isEmpty
            && Set(interfaces).count == interfaces.count
            && Set(discoverableByProjects).count == discoverableByProjects.count
            && Set(reusableByProjects).count == reusableByProjects.count
            && !evidenceRefs.isEmpty
            && evidenceRefs.allSatisfy(nonempty)
    }

    private func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isObjectID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.allSatisfy(\.isHexDigit)
    }
}

enum WorkflowReuseMode: String, Codable, Sendable {
    case reuseDirectly
    case extractSharedPackage
    case bridgeViaAPI
    case bridgeViaMCP
    case bridgeViaCLI
    case forkOrAdapt
    case rebuild
}

struct WorkflowReuseFactors: Codable, Sendable, Equatable {
    var functionalFit: Double
    var interfaceFit: Double
    var quality: Double
    var maturity: Double
    var health: Double
    var accessibility: Double
    var existingUsage: Double
    var knowledgeConfidence: Double
    var penalty: Double

    var isValid: Bool {
        [
            functionalFit, interfaceFit, quality, maturity, health,
            accessibility, existingUsage, knowledgeConfidence
        ].allSatisfy { $0.isFinite && (0...1).contains($0) }
            && penalty.isFinite
            && (0...100).contains(penalty)
    }

    var score: Double {
        max(0, min(100,
            25 * functionalFit
                + 15 * interfaceFit
                + 12 * quality
                + 10 * maturity
                + 10 * health
                + 10 * accessibility
                + 10 * existingUsage
                + 8 * knowledgeConfidence
                - penalty
        ))
    }
}

struct WorkflowTechnologyReuseRequest: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var targetProject: String
    var desiredCapability: String
    var catalogEntryID: String
    var expectedSourceRevision: String
    var factors: WorkflowReuseFactors
    var proposedMode: WorkflowReuseMode
    var rationale: [String]

    var isValid: Bool {
        schemaVersion == 1
            && [targetProject, desiredCapability, catalogEntryID]
                .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && (expectedSourceRevision.count == 40 || expectedSourceRevision.count == 64)
            && expectedSourceRevision.allSatisfy(\.isHexDigit)
            && factors.isValid
            && !rationale.isEmpty
            && rationale.allSatisfy {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }
}

struct WorkflowTechnologyReuseEvaluation: Sendable, Equatable {
    var eligible: Bool
    var score: Double
    var blockers: [String]
}

enum WorkflowTechnologyReuseEvaluator {
    static func evaluate(
        request: WorkflowTechnologyReuseRequest,
        entry: WorkflowTechnologyCatalogEntry
    ) -> WorkflowTechnologyReuseEvaluation {
        guard request.isValid, entry.isValid else {
            return .init(eligible: false, score: request.factors.score, blockers: ["reuse_input_invalid"])
        }
        let blockers = identityBlockers(request: request, entry: entry)
            + accessBlockers(request: request, entry: entry)
            + modeBlockers(request: request, entry: entry)
        return .init(
            eligible: blockers.isEmpty,
            score: request.factors.score,
            blockers: blockers.sorted()
        )
    }

    private static func identityBlockers(
        request: WorkflowTechnologyReuseRequest,
        entry: WorkflowTechnologyCatalogEntry
    ) -> [String] {
        var blockers: [String] = []
        if request.catalogEntryID != entry.id { blockers.append("catalog_identity_mismatch") }
        if request.expectedSourceRevision != entry.sourceRevision { blockers.append("source_revision_stale") }
        if !entry.capabilities.contains(request.desiredCapability) { blockers.append("capability_mismatch") }
        return blockers
    }

    private static func accessBlockers(
        request: WorkflowTechnologyReuseRequest,
        entry: WorkflowTechnologyCatalogEntry
    ) -> [String] {
        var blockers: [String] = []
        if !entry.discoverableByProjects.contains(request.targetProject) {
            blockers.append("catalog_entry_not_discoverable")
        }
        if !entry.reusableByProjects.contains(request.targetProject) {
            blockers.append("catalog_entry_not_reusable")
        }
        if [.deprecated, .unknown].contains(entry.lifecycle) { blockers.append("lifecycle_not_eligible") }
        return blockers
    }

    private static func modeBlockers(
        request: WorkflowTechnologyReuseRequest,
        entry: WorkflowTechnologyCatalogEntry
    ) -> [String] {
        switch request.proposedMode {
        case .bridgeViaMCP where !entry.interfaces.contains(.mcp):
            return ["mcp_interface_absent"]
        case .bridgeViaCLI where !entry.interfaces.contains(.commandLine):
            return ["cli_interface_absent"]
        case .bridgeViaAPI where entry.interfaces.allSatisfy({ ![.http, .grpc].contains($0) }):
            return ["service_interface_absent"]
        case .reuseDirectly where request.factors.score < 75:
            return ["direct_reuse_score_below_75"]
        default:
            return []
        }
    }
}
