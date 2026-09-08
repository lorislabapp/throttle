import Foundation
import ResearchVaultModel

public enum ResearchVaultIPCContract {
    public static let currentVersion = 1
    /// Maximum UTF-8 byte count of the decoded query string, before JSON escaping.
    public static let maximumQueryBytes = 4_096
    /// Maximum complete JSON request on the wire, checked before decoding.
    /// Separate from the decoded query budget: escaping and 64 project keys of
    /// up to 128 ASCII characters also occupy bytes in the envelope.
    public static let maximumSearchRequestBytes = 65_536
    public static let maximumResultCharacters = 50_000
    public static let maximumOwnerRequestBytes = 1_048_576
    public static let maximumReceiptsPerRequest = 32
    public static let maximumResponseBytes = 2_097_152
    public static let maximumReasoningRelations = 128
    public static let maximumReasoningFactsPerResponse = 256
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
                          of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#,
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
    /// Present for a virtual document projected from an immutable sealed
    /// receipt. Hashes of the projected text and original receipt are distinct.
    public let receiptProvenance: ResearchVaultReceiptProvenance?

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
        indexGeneration: String,
        receiptProvenance: ResearchVaultReceiptProvenance? = nil
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
        self.receiptProvenance = receiptProvenance
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
