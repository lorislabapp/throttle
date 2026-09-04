import Foundation
import ResearchVaultModel

public enum ResearchVaultIPCContract {
    public static let currentVersion = 1
    public static let maximumQueryBytes = 4_096
    public static let maximumResultCharacters = 50_000
    public static let maximumOwnerRequestBytes = 1_048_576
    public static let maximumReceiptsPerRequest = 32
    public static let maximumResponseBytes = 2_097_152
    public static let maximumReasoningRelations = 128
    public static let maximumReasoningFactsPerResponse = 256
}

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

/// Administrative input is content-only: no path, key, project grant or
/// sensitivity ceiling can be selected by the caller. Each receipt still
/// carries its own provenance and classification, which the endpoint's
/// immutable authorization validates server-side.
public struct ResearchVaultReceiptImportRequest: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let receipts: [ResearchReceipt]

    public init(
        contractVersion: Int = ResearchVaultIPCContract.currentVersion,
        receipts: [ResearchReceipt]
    ) {
        self.contractVersion = contractVersion
        self.receipts = receipts
    }

    public func validated() throws -> Self {
        guard contractVersion == ResearchVaultIPCContract.currentVersion else {
            throw ResearchVaultIPCValidationError.unsupportedContractVersion(contractVersion)
        }
        guard !receipts.isEmpty,
              receipts.count <= ResearchVaultIPCContract.maximumReceiptsPerRequest else {
            throw ResearchVaultIPCValidationError.invalidReceiptBatch
        }
        do {
            for receipt in receipts {
                try ResearchReceiptValidator.validate(receipt)
            }
        } catch {
            throw ResearchVaultIPCValidationError.invalidReceipt
        }
        return self
    }
}

public struct ResearchVaultReceiptImportResponse: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let insertedReceipts: Int
    public let alreadyPresentReceipts: Int

    public init(
        contractVersion: Int = ResearchVaultIPCContract.currentVersion,
        insertedReceipts: Int,
        alreadyPresentReceipts: Int
    ) {
        self.contractVersion = contractVersion
        self.insertedReceipts = insertedReceipts
        self.alreadyPresentReceipts = alreadyPresentReceipts
    }
}

public struct ResearchVaultQuarantineItem: Codable, Equatable, Sendable {
    public let receiptID: String
    public let projectKey: String
    public let question: String
    public let sensitivity: String
    public let createdAtMS: Int64
    public let sourceCount: Int
    public let firstSourceLocator: String?

    public init(
        receiptID: String,
        projectKey: String,
        question: String,
        sensitivity: String,
        createdAtMS: Int64,
        sourceCount: Int,
        firstSourceLocator: String?
    ) {
        self.receiptID = receiptID
        self.projectKey = projectKey
        self.question = question
        self.sensitivity = sensitivity
        self.createdAtMS = createdAtMS
        self.sourceCount = sourceCount
        self.firstSourceLocator = firstSourceLocator
    }
}

public struct ResearchVaultQuarantineListRequest: Codable, Equatable, Sendable {
    public let contractVersion: Int

    public init(contractVersion: Int = ResearchVaultIPCContract.currentVersion) {
        self.contractVersion = contractVersion
    }

    public func validated() throws -> Self {
        guard contractVersion == ResearchVaultIPCContract.currentVersion else {
            throw ResearchVaultIPCValidationError.unsupportedContractVersion(contractVersion)
        }
        return self
    }
}

public struct ResearchVaultQuarantineListResponse: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let items: [ResearchVaultQuarantineItem]

    public init(
        contractVersion: Int = ResearchVaultIPCContract.currentVersion,
        items: [ResearchVaultQuarantineItem]
    ) {
        self.contractVersion = contractVersion
        self.items = items
    }
}

public struct ResearchVaultReviewRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case approve
        case reject
    }

    public let contractVersion: Int
    public let action: Action
    public let receiptIDs: [String]

    public init(
        contractVersion: Int = ResearchVaultIPCContract.currentVersion,
        action: Action,
        receiptIDs: [String]
    ) {
        self.contractVersion = contractVersion
        self.action = action
        self.receiptIDs = receiptIDs
    }

    public func validated() throws -> Self {
        guard contractVersion == ResearchVaultIPCContract.currentVersion else {
            throw ResearchVaultIPCValidationError.unsupportedContractVersion(contractVersion)
        }
        guard !receiptIDs.isEmpty,
              receiptIDs.count <= ResearchVaultIPCContract.maximumReceiptsPerRequest,
              Set(receiptIDs).count == receiptIDs.count,
              receiptIDs.allSatisfy({ id in
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && id.utf8.count <= 256
              }) else {
            throw ResearchVaultIPCValidationError.invalidReviewBatch
        }
        return self
    }
}

public struct ResearchVaultReviewResponse: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let processed: Int

    public init(
        contractVersion: Int = ResearchVaultIPCContract.currentVersion,
        processed: Int
    ) {
        self.contractVersion = contractVersion
        self.processed = processed
    }
}

public struct ResearchVaultReceiptExportRequest: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let afterReceiptID: String?
    public let limit: Int

    public init(
        contractVersion: Int = ResearchVaultIPCContract.currentVersion,
        afterReceiptID: String? = nil,
        limit: Int = 8
    ) {
        self.contractVersion = contractVersion
        self.afterReceiptID = afterReceiptID
        self.limit = limit
    }

    public func validated() throws -> Self {
        guard contractVersion == ResearchVaultIPCContract.currentVersion else {
            throw ResearchVaultIPCValidationError.unsupportedContractVersion(contractVersion)
        }
        guard (1 ... ResearchVaultIPCContract.maximumReceiptsPerRequest).contains(limit),
              afterReceiptID.map({ UUID(uuidString: $0) != nil }) ?? true else {
            throw ResearchVaultIPCValidationError.invalidExportPage
        }
        return self
    }
}

public struct ResearchVaultReceiptExportResponse: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let receipts: [ResearchReceipt]
    public let nextReceiptID: String?

    public init(
        contractVersion: Int = ResearchVaultIPCContract.currentVersion,
        receipts: [ResearchReceipt],
        nextReceiptID: String?
    ) {
        self.contractVersion = contractVersion
        self.receipts = receipts
        self.nextReceiptID = nextReceiptID
    }
}

/// A caller may narrow a query to project keys, but it cannot widen the fixed
/// authorization attached to its authenticated XPC endpoint.
public struct ResearchVaultSearchRequest: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let query: String
    public let limit: Int
    public let maximumCharacters: Int
    public let projectKeys: [String]?

    public init(
        contractVersion: Int = ResearchVaultIPCContract.currentVersion,
        query: String,
        limit: Int = 8,
        maximumCharacters: Int = 12_000,
        projectKeys: [String]? = nil
    ) {
        self.contractVersion = contractVersion
        self.query = query
        self.limit = limit
        self.maximumCharacters = maximumCharacters
        self.projectKeys = projectKeys
    }

    public func validated() throws -> Self {
        guard contractVersion == ResearchVaultIPCContract.currentVersion else {
            throw ResearchVaultIPCValidationError.unsupportedContractVersion(contractVersion)
        }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query.utf8.count <= ResearchVaultIPCContract.maximumQueryBytes else {
            throw ResearchVaultIPCValidationError.invalidQuery
        }
        guard (1 ... 20).contains(limit) else {
            throw ResearchVaultIPCValidationError.invalidLimit
        }
        guard (256 ... ResearchVaultIPCContract.maximumResultCharacters)
            .contains(maximumCharacters) else {
            throw ResearchVaultIPCValidationError.invalidMaximumCharacters
        }
        if let projectKeys {
            guard !projectKeys.isEmpty,
                  projectKeys.count <= 64,
                  Set(projectKeys).count == projectKeys.count,
                  projectKeys.allSatisfy({
                      $0.range(
                          of: #"^[a-z0-9][a-z0-9._-]{0,63}$"#,
                          options: .regularExpression
                      ) != nil
                  }) else {
                throw ResearchVaultIPCValidationError.invalidProjectScope
            }
        }
        return self
    }
}

public enum ResearchVaultIPCValidationError: Error, Equatable, Sendable {
    case unsupportedContractVersion(Int)
    case invalidQuery
    case invalidLimit
    case invalidMaximumCharacters
    case invalidProjectScope
    case invalidReceiptBatch
    case invalidReceipt
    case invalidReviewBatch
    case invalidExportPage
    case invalidReasoningRelations
    case invalidReasoningQuery
}

public struct ResearchVaultCitation: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let documentID: String
    public let title: String
    public let libraryPath: String
    public let origins: [String]
    public let plaintextSHA256: String
    public let chunkOrdinal: Int
    public let locator: String
    public let excerptSHA256: String
    public let observedAt: Date
    public let sourceModifiedAt: Date?
    public let evidenceStatus: ResearchEvidenceStatus?
    public let indexGeneration: String

    public init(
        schemaVersion: Int = ResearchVaultCitation.currentSchemaVersion,
        documentID: String,
        title: String,
        libraryPath: String,
        origins: [String],
        plaintextSHA256: String,
        chunkOrdinal: Int,
        locator: String,
        excerptSHA256: String,
        observedAt: Date,
        sourceModifiedAt: Date?,
        evidenceStatus: ResearchEvidenceStatus?,
        indexGeneration: String
    ) {
        self.schemaVersion = schemaVersion
        self.documentID = documentID
        self.title = title
        self.libraryPath = libraryPath
        self.origins = origins
        self.plaintextSHA256 = plaintextSHA256
        self.chunkOrdinal = chunkOrdinal
        self.locator = locator
        self.excerptSHA256 = excerptSHA256
        self.observedAt = observedAt
        self.sourceModifiedAt = sourceModifiedAt
        self.evidenceStatus = evidenceStatus
        self.indexGeneration = indexGeneration
    }
}

public struct ResearchVaultContextItem: Codable, Equatable, Sendable {
    public let citation: ResearchVaultCitation
    public let heading: String?
    public let excerpt: String
    public let score: Double

    public init(
        citation: ResearchVaultCitation,
        heading: String?,
        excerpt: String,
        score: Double
    ) {
        self.citation = citation
        self.heading = heading
        self.excerpt = excerpt
        self.score = score
    }
}

public struct ResearchVaultContextBundle: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let query: String
    public let projectKeys: [String]
    public let maximumSensitivity: ResearchSensitivity
    public let items: [ResearchVaultContextItem]
    public let truncated: Bool

    public init(
        contractVersion: Int = ResearchVaultIPCContract.currentVersion,
        query: String,
        projectKeys: [String],
        maximumSensitivity: ResearchSensitivity,
        items: [ResearchVaultContextItem],
        truncated: Bool
    ) {
        self.contractVersion = contractVersion
        self.query = query
        self.projectKeys = projectKeys
        self.maximumSensitivity = maximumSensitivity
        self.items = items
        self.truncated = truncated
    }
}

public struct ResearchVaultHealthResponse: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let schemaVersion: Int
    public let cipherVersion: String
    public let receiptCount: Int
    public let documentCount: Int
    public let chunkCount: Int
    public let quickCheckPassed: Bool
    public let cipherIntegrityPassed: Bool
    public let foreignKeysPassed: Bool

    public init(
        contractVersion: Int = ResearchVaultIPCContract.currentVersion,
        schemaVersion: Int,
        cipherVersion: String,
        receiptCount: Int,
        documentCount: Int,
        chunkCount: Int,
        quickCheckPassed: Bool,
        cipherIntegrityPassed: Bool,
        foreignKeysPassed: Bool
    ) {
        self.contractVersion = contractVersion
        self.schemaVersion = schemaVersion
        self.cipherVersion = cipherVersion
        self.receiptCount = receiptCount
        self.documentCount = documentCount
        self.chunkCount = chunkCount
        self.quickCheckPassed = quickCheckPassed
        self.cipherIntegrityPassed = cipherIntegrityPassed
        self.foreignKeysPassed = foreignKeysPassed
    }
}

public struct ResearchVaultIPCErrorPayload: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case invalidRequest = "invalid_request"
        case unavailable
    }

    public let contractVersion: Int
    public let code: Code

    public init(
        contractVersion: Int = ResearchVaultIPCContract.currentVersion,
        code: Code
    ) {
        self.contractVersion = contractVersion
        self.code = code
    }
}
