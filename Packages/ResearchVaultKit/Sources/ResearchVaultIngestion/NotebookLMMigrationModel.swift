import CryptoKit
import Foundation
import ResearchVaultModel

public struct NotebookLMSourceProvenance: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let notebookURL: String
    public let sourceIndex: Int
    public let title: String
    public let exportedAt: Date
    public let payloadSHA256: String

    public init(
        schemaVersion: Int = NotebookLMSourceProvenance.schemaVersion,
        notebookURL: String,
        sourceIndex: Int,
        title: String,
        exportedAt: Date,
        payloadSHA256: String
    ) {
        self.schemaVersion = schemaVersion
        self.notebookURL = notebookURL
        self.sourceIndex = sourceIndex
        self.title = title
        self.exportedAt = exportedAt
        self.payloadSHA256 = payloadSHA256
    }
}

public struct NotebookLMMigrationFile: Codable, Equatable, Sendable {
    public let relativePath: String
    public let byteCount: Int
    public let extractedCharacterCount: Int
    public let sha256: String
    public let format: String
    public let notebookURL: String?
    public let sourceIndex: Int?
    public let sourceTitle: String?

    public init(
        relativePath: String,
        byteCount: Int,
        extractedCharacterCount: Int,
        sha256: String,
        format: String,
        notebookURL: String? = nil,
        sourceIndex: Int? = nil,
        sourceTitle: String? = nil
    ) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.extractedCharacterCount = extractedCharacterCount
        self.sha256 = sha256
        self.format = format
        self.notebookURL = notebookURL
        self.sourceIndex = sourceIndex
        self.sourceTitle = sourceTitle
    }
}

public struct NotebookLMMigrationManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let createdAt: Date
    public let projectKey: String
    public let sourceFolderName: String
    public let files: [NotebookLMMigrationFile]
    public let aggregateSHA256: String

    public init(
        schemaVersion: Int = NotebookLMMigrationManifest.schemaVersion,
        createdAt: Date,
        projectKey: String,
        sourceFolderName: String,
        files: [NotebookLMMigrationFile],
        aggregateSHA256: String
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.projectKey = projectKey
        self.sourceFolderName = sourceFolderName
        self.files = files
        self.aggregateSHA256 = aggregateSHA256
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct NotebookLMMigrationBatch: Sendable {
    public let receipts: [ResearchReceipt]
    public let manifest: NotebookLMMigrationManifest

    public init(receipts: [ResearchReceipt], manifest: NotebookLMMigrationManifest) {
        self.receipts = receipts
        self.manifest = manifest
    }
}
