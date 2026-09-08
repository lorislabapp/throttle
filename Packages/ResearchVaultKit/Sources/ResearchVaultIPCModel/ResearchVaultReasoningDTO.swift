import Foundation
import ResearchVaultModel

public enum ResearchVaultReasoningRelationKind: String, Codable, CaseIterable, Sendable {
    case contradicts
    case supersedes
    case dependsOn
}

public struct ResearchVaultReasoningClaimReference: Codable, Equatable, Hashable, Sendable {
    public let receiptID: String
    public let findingIndex: Int

    public init(receiptID: String, findingIndex: Int) {
        self.receiptID = receiptID
        self.findingIndex = findingIndex
    }
}

public struct ResearchVaultReasoningRelation: Codable, Equatable, Sendable {
    public let relation: ResearchVaultReasoningRelationKind
    public let subject: ResearchVaultReasoningClaimReference
    public let object: ResearchVaultReasoningClaimReference
    public let validFrom: Date?
    public let validUntil: Date?

    public init(
        relation: ResearchVaultReasoningRelationKind,
        subject: ResearchVaultReasoningClaimReference,
        object: ResearchVaultReasoningClaimReference,
        validFrom: Date? = nil,
        validUntil: Date? = nil
    ) {
        self.relation = relation
        self.subject = subject
        self.object = object
        self.validFrom = validFrom
        self.validUntil = validUntil
    }
}

/// This mutation exists only on the authenticated owner endpoint. It contains
/// no project, sensitivity, rule text or authority field; the service resolves
/// all references against approved receipts under its immutable grant.
public struct ResearchVaultReasoningPromotionRequest: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let relations: [ResearchVaultReasoningRelation]
    public let removingFactIDs: [String]

    public init(
        contractVersion: Int = ResearchVaultIPCContract.currentVersion,
        relations: [ResearchVaultReasoningRelation],
        removingFactIDs: [String] = []
    ) {
        self.contractVersion = contractVersion
        self.relations = relations
        self.removingFactIDs = removingFactIDs
    }

    public func validated() throws -> Self {
        guard contractVersion == ResearchVaultIPCContract.currentVersion else {
            throw ResearchVaultIPCValidationError.unsupportedContractVersion(contractVersion)
        }
        guard relations.count <= ResearchVaultIPCContract.maximumReasoningRelations,
              removingFactIDs.count <= ResearchVaultIPCContract.maximumReasoningRelations,
              Set(removingFactIDs).count == removingFactIDs.count,
              removingFactIDs.allSatisfy({
                  $0.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
              }) else {
            throw ResearchVaultIPCValidationError.invalidReasoningRelations
        }
        for relation in relations {
            guard relation.subject != relation.object,
                  UUID(uuidString: relation.subject.receiptID) != nil,
                  UUID(uuidString: relation.object.receiptID) != nil,
                  (0 ... 10_000).contains(relation.subject.findingIndex),
                  (0 ... 10_000).contains(relation.object.findingIndex),
                  relation.validFrom == nil || relation.validUntil == nil
                    || relation.validFrom! <= relation.validUntil! else {
                throw ResearchVaultIPCValidationError.invalidReasoningRelations
            }
        }
        return self
    }
}

public struct ResearchVaultReasoningRefreshResponse: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let generation: Int64
    public let baseFactCount: Int
    public let derivedFactCount: Int
    public let relationCount: Int
    public let shadowMode: Bool

    public init(
        contractVersion: Int = ResearchVaultIPCContract.currentVersion,
        generation: Int64,
        baseFactCount: Int,
        derivedFactCount: Int,
        relationCount: Int,
        shadowMode: Bool
    ) {
        self.contractVersion = contractVersion
        self.generation = generation
        self.baseFactCount = baseFactCount
        self.derivedFactCount = derivedFactCount
        self.relationCount = relationCount
        self.shadowMode = shadowMode
    }
}

public enum ResearchVaultReasoningQueryKind: String, Codable, CaseIterable, Sendable {
    case facts
    case why
    case impacted
    case whatChanged
    case contradictions
}

public struct ResearchVaultReasoningQuery: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let kind: ResearchVaultReasoningQueryKind
    public let factID: String?
    public let limit: Int

    public init(
        contractVersion: Int = ResearchVaultIPCContract.currentVersion,
        kind: ResearchVaultReasoningQueryKind,
        factID: String? = nil,
        limit: Int = 64
    ) {
        self.contractVersion = contractVersion
        self.kind = kind
        self.factID = factID
        self.limit = limit
    }

    public func validated() throws -> Self {
        guard contractVersion == ResearchVaultIPCContract.currentVersion else {
            throw ResearchVaultIPCValidationError.unsupportedContractVersion(contractVersion)
        }
        guard (1 ... ResearchVaultIPCContract.maximumReasoningFactsPerResponse).contains(limit) else {
            throw ResearchVaultIPCValidationError.invalidReasoningQuery
        }
        let needsFact = kind == .why || kind == .impacted
        guard !needsFact || factID?.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil else {
            throw ResearchVaultIPCValidationError.invalidReasoningQuery
        }
        guard needsFact || factID == nil else {
            throw ResearchVaultIPCValidationError.invalidReasoningQuery
        }
        return self
    }
}

public struct ResearchVaultReasoningFactDTO: Codable, Equatable, Sendable {
    public let id: String
    public let predicate: String
    public let arguments: [String]
    public let projectKey: String
    public let sensitivity: ResearchSensitivity
    public let asserted: Bool
    public let receiptIDs: [String]
    public let sourceIDs: [String]

    public init(
        id: String,
        predicate: String,
        arguments: [String],
        projectKey: String,
        sensitivity: ResearchSensitivity,
        asserted: Bool,
        receiptIDs: [String],
        sourceIDs: [String]
    ) {
        self.id = id
        self.predicate = predicate
        self.arguments = arguments
        self.projectKey = projectKey
        self.sensitivity = sensitivity
        self.asserted = asserted
        self.receiptIDs = receiptIDs
        self.sourceIDs = sourceIDs
    }
}

public struct ResearchVaultReasoningDerivationDTO: Codable, Equatable, Sendable {
    public let conclusionFactID: String
    public let ruleID: String
    public let premiseFactIDs: [String]

    public init(conclusionFactID: String, ruleID: String, premiseFactIDs: [String]) {
        self.conclusionFactID = conclusionFactID
        self.ruleID = ruleID
        self.premiseFactIDs = premiseFactIDs
    }
}

public struct ResearchVaultReasoningQueryResponse: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let kind: ResearchVaultReasoningQueryKind
    public let generation: Int64
    public let facts: [ResearchVaultReasoningFactDTO]
    public let derivations: [ResearchVaultReasoningDerivationDTO]
    public let addedFactIDs: [String]
    public let removedFactIDs: [String]
    public let updatedFactIDs: [String]
    public let truncated: Bool

    public init(
        contractVersion: Int = ResearchVaultIPCContract.currentVersion,
        kind: ResearchVaultReasoningQueryKind,
        generation: Int64,
        facts: [ResearchVaultReasoningFactDTO],
        derivations: [ResearchVaultReasoningDerivationDTO],
        addedFactIDs: [String] = [],
        removedFactIDs: [String] = [],
        updatedFactIDs: [String] = [],
        truncated: Bool
    ) {
        self.contractVersion = contractVersion
        self.kind = kind
        self.generation = generation
        self.facts = facts
        self.derivations = derivations
        self.addedFactIDs = addedFactIDs
        self.removedFactIDs = removedFactIDs
        self.updatedFactIDs = updatedFactIDs
        self.truncated = truncated
    }
}
