import Foundation
import ResearchVaultModel

public enum ResearchVaultIPCContract {
    public static let currentVersion = 1
    public static let maximumQueryBytes = 4_096
    public static let maximumResultCharacters = 50_000
    public static let maximumOwnerRequestBytes = 1_048_576
    public static let maximumReceiptsPerRequest = 32
    public static let maximumResponseBytes = 2_097_152
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

/// Query requests intentionally contain no project, sensitivity, path, key or
/// capability. The service binds all authorization to its authenticated XPC
/// endpoint before decoding a request.
public struct ResearchVaultSearchRequest: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let query: String
    public let limit: Int
    public let maximumCharacters: Int

    public init(
        contractVersion: Int = ResearchVaultIPCContract.currentVersion,
        query: String,
        limit: Int = 8,
        maximumCharacters: Int = 12_000
    ) {
        self.contractVersion = contractVersion
        self.query = query
        self.limit = limit
        self.maximumCharacters = maximumCharacters
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
        return self
    }
}

public enum ResearchVaultIPCValidationError: Error, Equatable, Sendable {
    case unsupportedContractVersion(Int)
    case invalidQuery
    case invalidLimit
    case invalidMaximumCharacters
    case invalidReceiptBatch
    case invalidReceipt
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
