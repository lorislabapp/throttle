import CryptoKit
import Foundation

enum WorkflowPlatform: String, Codable, Sendable, CaseIterable {
    case macOS, iOS, visionOS, android, server, web
}

struct WorkflowRequirement: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var statement: String
    var acceptanceCriteria: [String]
    var blocking: Bool = true
}

enum WorkflowInputKind: String, Codable, Sendable {
    case file, decision, research, artifact
}

struct WorkflowInputReference: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var kind: WorkflowInputKind
    var reference: String
    var contentDigest: String?
}

enum WorkflowApprovalScope: String, Codable, Sendable {
    case perAction, session, standing
}

/// An obligation to obtain authority. Its presence never means authority exists.
struct WorkflowPermissionRequirement: Codable, Sendable, Equatable {
    var capability: String
    var action: String
    var target: String
    var approvalScope: WorkflowApprovalScope
}

enum WorkflowBudgetKnowledge: String, Codable, Sendable {
    case exact, unknown
}

struct WorkflowBudgetAmount: Codable, Sendable, Equatable {
    var knowledge: WorkflowBudgetKnowledge
    var value: Int?
    var unit: String

    static func unknown(unit: String) -> Self {
        Self(knowledge: .unknown, value: nil, unit: unit)
    }

    var isValid: Bool {
        guard !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch knowledge {
        case .exact: return value.map { $0 > 0 } == true
        case .unknown: return value == nil
        }
    }
}

struct WorkflowBudgetContract: Codable, Sendable, Equatable {
    var purpose: BudgetPurpose = .ordinary
    var tokenLimit: WorkflowBudgetAmount = .unknown(unit: "tokens")
    var costLimit: WorkflowBudgetAmount = .unknown(unit: "minor-currency-unit")
    var wallClockLimit: WorkflowBudgetAmount = .unknown(unit: "seconds")

    init(
        purpose: BudgetPurpose = .ordinary,
        tokenLimit: WorkflowBudgetAmount = .unknown(unit: "tokens"),
        costLimit: WorkflowBudgetAmount = .unknown(unit: "minor-currency-unit"),
        wallClockLimit: WorkflowBudgetAmount = .unknown(unit: "seconds")
    ) {
        self.purpose = purpose
        self.tokenLimit = tokenLimit
        self.costLimit = costLimit
        self.wallClockLimit = wallClockLimit
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        purpose = try values.decodeIfPresent(BudgetPurpose.self, forKey: .purpose) ?? .ordinary
        tokenLimit = try values.decodeIfPresent(WorkflowBudgetAmount.self, forKey: .tokenLimit)
            ?? .unknown(unit: "tokens")
        costLimit = try values.decodeIfPresent(WorkflowBudgetAmount.self, forKey: .costLimit)
            ?? .unknown(unit: "minor-currency-unit")
        wallClockLimit = try values.decodeIfPresent(WorkflowBudgetAmount.self, forKey: .wallClockLimit)
            ?? .unknown(unit: "seconds")
    }

    var isValid: Bool {
        tokenLimit.isValid && costLimit.isValid && wallClockLimit.isValid
    }
}

struct WorkflowWorkContract: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var revision: Int
    var objective: String
    var approvedProductReference: String
    var requirements: [WorkflowRequirement]
    var allowedChangePaths: [String]
    var mustPreserve: [String]
    var exclusions: [String]
    var platforms: [WorkflowPlatform]
    var baseRevision: String
    var inputs: [WorkflowInputReference]
    var permissionRequirements: [WorkflowPermissionRequirement]
    var budget: WorkflowBudgetContract
    var verification: WorkflowVerificationContract?
    var recipe: WorkflowRecipeReference?
    var reviewRubric: WorkflowReviewRubric?
    var design: WorkflowDesignContract?
    var productCycle: WorkflowProductCycleContract?

    var digest: String? {
        guard isValid else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var isValid: Bool {
        let requirementIDs = requirements.map(\.id)
        let inputIDs = inputs.map(\.id)
        return schemaVersion == 1
            && revision > 0
            && nonempty(objective)
            && nonempty(approvedProductReference)
            && !requirements.isEmpty
            && Set(requirementIDs).count == requirementIDs.count
            && requirements.allSatisfy(validRequirement)
            && !allowedChangePaths.isEmpty
            && allowedChangePaths.allSatisfy(validPathScope)
            && Set(allowedChangePaths).count == allowedChangePaths.count
            && !mustPreserve.isEmpty
            && mustPreserve.allSatisfy(nonempty)
            && exclusions.allSatisfy(nonempty)
            && !platforms.isEmpty
            && Set(platforms).count == platforms.count
            && isObjectID(baseRevision)
            && Set(inputIDs).count == inputIDs.count
            && inputs.allSatisfy(validInput)
            && permissionRequirements.allSatisfy(validPermission)
            && budget.isValid
            && verification.map { $0.digest != nil } ?? true
            && recipe.map { WorkflowRecipeCatalog.resolve($0) != nil } ?? true
            && reviewRubric.map(\.isValid) ?? true
            && design.map { validDesign($0) } ?? true
            && productCycle.map(\.isValid) ?? true
    }

    func disallowedChanges(_ paths: [String]) -> [String] {
        paths.filter { path in
            !allowedChangePaths.contains { scope in
                scope.hasSuffix("/") ? path.hasPrefix(scope) : path == scope
            }
        }.sorted()
    }

    private func validRequirement(_ requirement: WorkflowRequirement) -> Bool {
        nonempty(requirement.id)
            && nonempty(requirement.statement)
            && !requirement.acceptanceCriteria.isEmpty
            && requirement.acceptanceCriteria.allSatisfy(nonempty)
    }

    private func validInput(_ input: WorkflowInputReference) -> Bool {
        guard nonempty(input.id), nonempty(input.reference) else { return false }
        if input.kind == .file {
            guard validPathScope(input.reference), let digest = input.contentDigest else { return false }
            return isDigest(digest)
        }
        return input.contentDigest.map(isDigest) ?? true
    }

    private func validPermission(_ permission: WorkflowPermissionRequirement) -> Bool {
        nonempty(permission.capability) && nonempty(permission.action) && nonempty(permission.target)
    }

    private func validDesign(_ design: WorkflowDesignContract) -> Bool {
        guard design.isValid, let rubric = reviewRubric else { return false }
        let rubricDimensions = Set(rubric.criteria.map(\.dimension))
        let adaptations = Set(design.platformAdaptations.map(\.platform))
        let designedPlatforms = Set(platforms.filter { $0 != .server })
        return designedPlatforms.isSubset(of: adaptations)
            && design.evidenceRequirements.allSatisfy { requirement in
                rubric.criteria.contains { criterion in
                    criterion.dimension == requirement.dimension
                        && !Set(criterion.acceptedEvidenceKinds)
                            .isDisjoint(with: requirement.acceptedEvidenceKinds)
                }
            }
            && Set([
                WorkflowReviewDimension.userExperience,
                .accessibility,
                .platform
            ]).isSubset(of: rubricDimensions)
    }

    private func validPathScope(_ path: String) -> Bool {
        nonempty(path)
            && !path.hasPrefix("/")
            && path != ".."
            && !path.hasPrefix("../")
            && !path.contains("/../")
            && path.rangeOfCharacter(from: .controlCharacters) == nil
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
}
