import CryptoKit
import Foundation
import ResearchVaultIngestion
import ResearchVaultModel
import ResearchVaultReasoning
import ResearchVaultStore

public enum SQLCipherVaultError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case corruptSchema
    case integrityFailure
    case documentIDConflict(String)
    case emptyDocumentQuery
}

public struct SQLCipherIntegrityEvidence: Equatable, Sendable {
    public let schemaVersion: Int
    public let cipherVersion: String
    public let receiptCount: Int
    public let documentCount: Int
    public let chunkCount: Int
    public let quickCheckPassed: Bool
    public let cipherIntegrityPassed: Bool
    public let foreignKeysPassed: Bool

    public init(
        schemaVersion: Int,
        cipherVersion: String,
        receiptCount: Int,
        documentCount: Int,
        chunkCount: Int,
        quickCheckPassed: Bool,
        cipherIntegrityPassed: Bool,
        foreignKeysPassed: Bool
    ) {
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

public struct SQLCipherBackupEvidence: Equatable, Sendable {
    public let schemaVersion: Int
    public let cipherVersion: String
    public let receiptCount: Int
    public let documentCount: Int
    public let chunkCount: Int
    public let byteCount: Int64
    public let ciphertextSHA256: String

    public init(
        schemaVersion: Int,
        cipherVersion: String,
        receiptCount: Int,
        documentCount: Int,
        chunkCount: Int,
        byteCount: Int64,
        ciphertextSHA256: String
    ) {
        self.schemaVersion = schemaVersion
        self.cipherVersion = cipherVersion
        self.receiptCount = receiptCount
        self.documentCount = documentCount
        self.chunkCount = chunkCount
        self.byteCount = byteCount
        self.ciphertextSHA256 = ciphertextSHA256
    }
}

public struct QuarantinedReceiptSummary: Codable, Equatable, Sendable {
    public let receiptID: String
    public let projectKey: String
    public let question: String
    public let sensitivity: ResearchSensitivity
    public let createdAt: Date
    public let sourceCount: Int
    public let firstSourceLocator: String?

    public init(
        receiptID: String,
        projectKey: String,
        question: String,
        sensitivity: ResearchSensitivity,
        createdAt: Date,
        sourceCount: Int,
        firstSourceLocator: String?
    ) {
        self.receiptID = receiptID
        self.projectKey = projectKey
        self.question = question
        self.sensitivity = sensitivity
        self.createdAt = createdAt
        self.sourceCount = sourceCount
        self.firstSourceLocator = firstSourceLocator
    }
}

public enum SQLCipherBackupError: Error, Equatable, Sendable {
    case invalidKeyLength
    case destinationExists
    case verificationFailed
}

/// Persistent encrypted receipt store backed by the official SQLCipher runtime.
/// All access filters are applied in SQL before receipt payloads or FTS rows are
/// returned to Swift.
public actor SQLCipherReceiptStore: ReceiptStore, ClaimSearchStore {
    public static let currentSchemaVersion = 7

    let connection: SQLCipherConnection
    let encoder: JSONEncoder
    let decoder: JSONDecoder

    public init(databaseURL: URL, key: Data) throws {
        guard key.count == 32 else {
            throw SQLCipherStoreError(code: -1, operation: "invalid-key-length")
        }
        let parent = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: parent.path
        )

        let connection = try SQLCipherConnection(path: databaseURL.path, key: key)
        try SQLCipherSchema.migrate(connection)
        self.connection = connection

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    public func close() {
        connection.close()
    }

    /// Function words that must not reach the FTS query.
    ///
    /// `unicode61` carries no stoplist and every token is OR'd, so a written
    /// question lets BM25 favour whichever long document happens to contain the
    /// most common words, whatever its subject. Measured on the sibling
    /// DeepSearsh index, which builds its query the same way: a question about
    /// running a Coral TPU beside a GPU returned a report on non-violent
    /// physical protection for a lone parent, and the same four hub documents
    /// came back for unrelated questions.
    ///
    /// A golden set derived from document titles cannot detect this — its
    /// queries are keywords and carry no function words — which is why it went
    /// unseen. Both languages are listed because the corpus and the questions
    /// mix French and English freely.
    static let ftsStopwords: Set<String> = [
        // French
        "ait", "alors", "au", "aussi", "autre", "aux", "avec", "avoir",
        "avais", "avait", "beaucoup", "bien", "car", "ce", "cela", "ces", "cet",
        "cette", "ceux", "chez", "comme", "coup", "dans", "de", "deja", "des",
        "donc", "dont", "du", "elle", "elles", "en", "encore", "entre", "est",
        "et", "etait", "etc", "etre", "faire", "fait", "faut", "genre",
        "ici", "il", "ils", "je", "la", "le", "les", "leur", "lui", "ma", "mais",
        "me", "meme", "mes", "moi", "mon", "ne", "ni", "nos", "notre", "nous",
        "on", "ont", "ou", "par", "parce", "pas", "peu", "peut", "plus", "pour",
        "pourquoi", "quand", "que", "quel", "quelle", "qui", "quoi", "sa",
        "sans", "se", "ses", "si", "sinon", "sur", "ta", "te", "tes", "toi",
        "ton", "tous", "tout", "toute", "toutes", "tres", "tu", "un", "une",
        "va", "vais", "vers", "veut", "veux", "voir", "vos", "votre", "vous",
        // English
        "about", "all", "also", "am", "an", "and", "any", "are", "as", "at",
        "be", "been", "but", "by", "could", "did", "do", "does", "for",
        "from", "get", "had", "has", "have", "how", "if", "in", "is", "it",
        "its", "just", "like", "more", "my", "no", "not", "of", "one", "or",
        "our", "out", "should", "so", "some", "that", "the", "their", "them",
        "then", "there", "these", "they", "this", "to", "too", "up", "us",
        "was", "we", "were", "what", "when", "where", "which", "who", "why",
        "will", "with", "would", "you", "your",
    ]
}

extension SQLCipherValue {
    var textValue: String? {
        if case let .text(value) = self { return value }
        return nil
    }

    var blobValue: Data? {
        if case let .blob(value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case let .real(value): return value
        case let .integer(value): return Double(value)
        default: return nil
        }
    }

    var integerValue: Int64? {
        if case let .integer(value) = self { return value }
        return nil
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
