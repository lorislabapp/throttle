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
    public static let currentSchemaVersion = 6

    let connection: SQLCipherConnection
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

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
        try Self.migrate(connection)
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

    public func importReceipt(
        _ receipt: ResearchReceipt,
        authorization: VaultAuthorization,
        reviewState: ResearchReviewState
    ) throws -> ReceiptImportResult {
        guard authorization.permits(
            projectKey: receipt.projectKey,
            sensitivity: receipt.sensitivity
        ) else {
            throw ReceiptStoreError.authorizationDenied
        }
        try ResearchReceiptValidator.validate(receipt)

        if let existingHash = try connection.scalarText(
            "SELECT content_hash FROM receipts WHERE receipt_id = ?1;",
            binds: [.text(receipt.receiptID)]
        ) {
            guard existingHash == receipt.contentHash else {
                throw ReceiptStoreError.receiptIDConflict(receipt.receiptID)
            }
            return .alreadyPresent
        }

        try connection.transaction {
            try insertValidatedReceipt(receipt, reviewState: reviewState)
        }
        return .inserted
    }

    /// Preflights every authorization, hash and conflict before one atomic
    /// transaction. A hostile or conflicting element therefore cannot leave a
    /// partially accepted batch behind.
    public func importReceipts(
        _ receipts: [ResearchReceipt],
        authorization: VaultAuthorization,
        reviewState: ResearchReviewState
    ) throws -> ReceiptBatchImportResult {
        var missing: [ResearchReceipt] = []
        var present = 0
        var batchHashes: [String: String] = [:]
        for receipt in receipts {
            guard authorization.permits(
                projectKey: receipt.projectKey,
                sensitivity: receipt.sensitivity
            ) else { throw ReceiptStoreError.authorizationDenied }
            try ResearchReceiptValidator.validate(receipt)
            if let priorHash = batchHashes[receipt.receiptID] {
                guard priorHash == receipt.contentHash else {
                    throw ReceiptStoreError.receiptIDConflict(receipt.receiptID)
                }
                present += 1
                continue
            }
            batchHashes[receipt.receiptID] = receipt.contentHash
            if let existingHash = try connection.scalarText(
                "SELECT content_hash FROM receipts WHERE receipt_id = ?1;",
                binds: [.text(receipt.receiptID)]
            ) {
                guard existingHash == receipt.contentHash else {
                    throw ReceiptStoreError.receiptIDConflict(receipt.receiptID)
                }
                present += 1
            } else {
                missing.append(receipt)
            }
        }

        try connection.transaction {
            for receipt in missing {
                try insertValidatedReceipt(receipt, reviewState: reviewState)
            }
        }
        return ReceiptBatchImportResult(
            insertedReceipts: missing.count,
            alreadyPresentReceipts: present
        )
    }

    private func insertValidatedReceipt(
        _ receipt: ResearchReceipt,
        reviewState: ResearchReviewState
    ) throws {
        let payload = try encoder.encode(receipt)
        try connection.execute(
            """
            INSERT INTO receipts(
                receipt_id, project_key, sensitivity, sensitivity_rank,
                created_at_ms, content_hash, payload, review_state
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);
            """,
            binds: [
                .text(receipt.receiptID),
                .text(receipt.projectKey),
                .text(receipt.sensitivity.rawValue),
                .integer(Int64(receipt.sensitivity.policyRank)),
                .integer(Self.milliseconds(receipt.createdAt)),
                .text(receipt.contentHash),
                .blob(payload),
                .text(reviewState.rawValue),
            ]
        )

        for source in receipt.sources {
            try connection.execute(
                """
                INSERT INTO sources(
                    receipt_id, source_id, kind, locator, observed_at_ms, plaintext_sha256
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6);
                """,
                binds: [
                    .text(receipt.receiptID),
                    .text(source.id),
                    .text(source.kind.rawValue),
                    .text(source.locator),
                    .integer(Self.milliseconds(source.observedAt)),
                    .text(source.sha256),
                ]
            )
        }

        for finding in receipt.findings {
            try connection.execute(
                "INSERT INTO findings(receipt_id, claim, status) VALUES (?1, ?2, ?3);",
                binds: [
                    .text(receipt.receiptID),
                    .text(finding.claim),
                    .text(finding.status.rawValue),
                ]
            )
            guard let findingID = try connection.scalarInteger("SELECT last_insert_rowid();") else {
                throw SQLCipherVaultError.corruptSchema
            }
            for evidenceID in finding.evidenceIDs {
                try connection.execute(
                    """
                    INSERT INTO finding_evidence(finding_id, receipt_id, source_id)
                    VALUES (?1, ?2, ?3);
                    """,
                    binds: [
                        .integer(findingID),
                        .text(receipt.receiptID),
                        .text(evidenceID),
                    ]
                )
            }
        }
    }

    public func receipt(
        id: String,
        authorization: VaultAuthorization
    ) throws -> ResearchReceipt? {
        guard !authorization.projectKeys.isEmpty else {
            throw ReceiptStoreError.authorizationDenied
        }
        let (projectClause, projectBinds) = Self.projectFilter(
            authorization.projectKeys,
            firstParameter: 3
        )
        let rows = try connection.rows(
            """
            SELECT payload FROM receipts
            WHERE receipt_id = ?1
              AND sensitivity_rank <= ?2
              AND review_state = 'approved'
              AND project_key IN (\(projectClause));
            """,
            binds: [
                .text(id),
                .integer(Int64(authorization.maximumSensitivity.policyRank)),
            ] + projectBinds
        )
        guard let payload = rows.first?.first?.blobValue else {
            let exists = try connection.scalarInteger(
                "SELECT count(*) FROM receipts WHERE receipt_id = ?1 AND review_state = 'approved';",
                binds: [.text(id)]
            ) ?? 0
            if exists > 0 { throw ReceiptStoreError.authorizationDenied }
            return nil
        }
        return try decodeAndValidate(payload)
    }

    public func receipts(authorization: VaultAuthorization) throws -> [ResearchReceipt] {
        guard !authorization.projectKeys.isEmpty else { return [] }
        let (projectClause, projectBinds) = Self.projectFilter(
            authorization.projectKeys,
            firstParameter: 2
        )
        let rows = try connection.rows(
            """
            SELECT payload FROM receipts
            WHERE sensitivity_rank <= ?1
              AND review_state = 'approved'
              AND project_key IN (\(projectClause))
            ORDER BY created_at_ms ASC, receipt_id ASC;
            """,
            binds: [
                .integer(Int64(authorization.maximumSensitivity.policyRank)),
            ] + projectBinds
        )
        return try rows.map { row in
            guard let payload = row.first?.blobValue else {
                throw SQLCipherVaultError.corruptSchema
            }
            return try decodeAndValidate(payload)
        }
    }

    public func quarantinedReceipts(
        authorization: VaultAuthorization
    ) throws -> [QuarantinedReceiptSummary] {
        guard !authorization.projectKeys.isEmpty else { return [] }
        let (projectClause, projectBinds) = Self.projectFilter(
            authorization.projectKeys,
            firstParameter: 2
        )
        let rows = try connection.rows(
            """
            SELECT r.payload,
                   (SELECT count(*) FROM sources s WHERE s.receipt_id = r.receipt_id),
                   (SELECT s.locator FROM sources s
                    WHERE s.receipt_id = r.receipt_id
                    ORDER BY s.source_id ASC LIMIT 1)
            FROM receipts r
            WHERE r.review_state = 'quarantined'
              AND r.sensitivity_rank <= ?1
              AND r.project_key IN (\(projectClause))
            ORDER BY r.created_at_ms DESC, r.receipt_id ASC;
            """,
            binds: [
                .integer(Int64(authorization.maximumSensitivity.policyRank)),
            ] + projectBinds
        )
        return try rows.map { row in
            guard
                let payload = row[safe: 0]?.blobValue,
                let sourceCount = row[safe: 1]?.integerValue
            else { throw SQLCipherVaultError.corruptSchema }
            let receipt = try decodeAndValidate(payload)
            return QuarantinedReceiptSummary(
                receiptID: receipt.receiptID,
                projectKey: receipt.projectKey,
                question: receipt.question,
                sensitivity: receipt.sensitivity,
                createdAt: receipt.createdAt,
                sourceCount: Int(sourceCount),
                firstSourceLocator: row[safe: 2]?.textValue
            )
        }
    }

    public func approveReceipts(ids: [String]) throws -> Int {
        let uniqueIDs = Array(Set(ids.filter { !$0.isEmpty })).sorted()
        guard !uniqueIDs.isEmpty else { return 0 }
        let placeholders = uniqueIDs.indices.map { "?" + String($0 + 1) }.joined(separator: ", ")
        var changed = 0
        try connection.transaction {
            try connection.execute(
                "UPDATE receipts SET review_state = 'approved' "
                    + "WHERE review_state = 'quarantined' AND receipt_id IN (" + placeholders + ");",
                binds: uniqueIDs.map(SQLCipherBind.text)
            )
            changed = Int(try connection.scalarInteger("SELECT changes();") ?? 0)
        }
        return changed
    }

    public func rejectReceipts(ids: [String]) throws -> Int {
        let uniqueIDs = Array(Set(ids.filter { !$0.isEmpty })).sorted()
        guard !uniqueIDs.isEmpty else { return 0 }
        let placeholders = uniqueIDs.indices.map { "?" + String($0 + 1) }.joined(separator: ", ")
        var changed = 0
        try connection.transaction {
            try connection.execute(
                "DELETE FROM receipts "
                    + "WHERE review_state = 'quarantined' AND receipt_id IN (" + placeholders + ");",
                binds: uniqueIDs.map(SQLCipherBind.text)
            )
            changed = Int(try connection.scalarInteger("SELECT changes();") ?? 0)
        }
        return changed
    }

    public func searchClaims(
        query: String,
        limit: Int = 20,
        authorization: VaultAuthorization
    ) throws -> [ClaimSearchHit] {
        guard !authorization.projectKeys.isEmpty else { return [] }
        let match = try Self.safeFTSQuery(query)
        let boundedLimit = min(max(limit, 1), 100)
        let (projectClause, projectBinds) = Self.projectFilter(
            authorization.projectKeys,
            firstParameter: 3
        )
        let limitParameter = 3 + projectBinds.count
        let rows = try connection.rows(
            """
            SELECT r.receipt_id, r.project_key, r.sensitivity,
                   f.claim, f.status, bm25(finding_fts)
            FROM finding_fts
            JOIN findings f ON f.id = finding_fts.rowid
            JOIN receipts r ON r.receipt_id = f.receipt_id
            WHERE finding_fts MATCH ?1
              AND r.sensitivity_rank <= ?2
              AND r.review_state = 'approved'
              AND r.project_key IN (\(projectClause))
            ORDER BY bm25(finding_fts) ASC, f.id ASC
            LIMIT ?\(limitParameter);
            """,
            binds: [
                .text(match),
                .integer(Int64(authorization.maximumSensitivity.policyRank)),
            ] + projectBinds + [.integer(Int64(boundedLimit))]
        )

        return try rows.map { row in
            guard
                let receiptID = row[safe: 0]?.textValue,
                let projectKey = row[safe: 1]?.textValue,
                let sensitivityText = row[safe: 2]?.textValue,
                let sensitivity = ResearchSensitivity(rawValue: sensitivityText),
                let claim = row[safe: 3]?.textValue,
                let statusText = row[safe: 4]?.textValue,
                let status = ResearchEvidenceStatus(rawValue: statusText),
                let rawRank = row[safe: 5]?.doubleValue
            else {
                throw SQLCipherVaultError.corruptSchema
            }
            return ClaimSearchHit(
                receiptID: receiptID,
                projectKey: projectKey,
                sensitivity: sensitivity,
                claim: claim,
                status: status,
                score: -rawRank
            )
        }
    }

    public func importDocument(
        _ document: ResearchDocumentCandidate,
        authorization: VaultAuthorization,
        reviewState: ResearchReviewState,
        chunker: ResearchDocumentChunker = .standard
    ) throws -> ResearchDocumentImportResult {
        guard authorization.permits(
            projectKey: document.projectKey,
            sensitivity: document.sensitivity
        ) else { throw ReceiptStoreError.authorizationDenied }
        guard document.plaintextSHA256.count == 64,
              document.byteCount == document.content.utf8.count,
              !document.documentID.isEmpty,
              !document.title.isEmpty else { throw SQLCipherVaultError.corruptSchema }
        if let existingHash = try connection.scalarText(
            "SELECT plaintext_sha256 FROM documents WHERE document_id = ?1;",
            binds: [.text(document.documentID)]
        ) {
            guard existingHash == document.plaintextSHA256 else {
                throw SQLCipherVaultError.documentIDConflict(document.documentID)
            }
            return .alreadyPresent
        }
        let chunks = chunker.chunks(for: document.content)
        guard !chunks.isEmpty else { throw SQLCipherVaultError.corruptSchema }
        let origins = try encoder.encode(document.origins)
        let observedAt = Date()
        try connection.transaction {
            try connection.execute(
                """
                INSERT INTO documents(
                    document_id, project_key, sensitivity, sensitivity_rank,
                    title, category, library_path, origins_json, content,
                    plaintext_sha256, byte_count, modified_at_ms, observed_at_ms,
                    evidence_status, review_state
                ) VALUES (
                    ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, NULL, ?14
                );
                """,
                binds: [
                    .text(document.documentID), .text(document.projectKey),
                    .text(document.sensitivity.rawValue),
                    .integer(Int64(document.sensitivity.policyRank)),
                    .text(document.title), .text(document.category),
                    .text(document.libraryPath), .blob(origins), .text(document.content),
                    .text(document.plaintextSHA256), .integer(Int64(document.byteCount)),
                    .integer(Self.milliseconds(document.modifiedAt)),
                    .integer(Self.milliseconds(observedAt)),
                    .text(reviewState.rawValue),
                ]
            )
            for chunk in chunks {
                try connection.execute(
                    """
                    INSERT INTO document_chunks(
                        document_id, ordinal, title, heading, content, approximate_token_count
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6);
                    """,
                    binds: [
                        .text(document.documentID), .integer(Int64(chunk.ordinal)),
                        .text(document.title), chunk.heading.map(SQLCipherBind.text) ?? .null,
                        .text(chunk.content), .integer(Int64(chunk.approximateTokenCount)),
                    ]
                )
            }
        }
        return .inserted(chunkCount: chunks.count)
    }

    public func searchDocuments(
        query: String,
        limit: Int = 20,
        authorization: VaultAuthorization
    ) throws -> [ResearchDocumentSearchHit] {
        guard !authorization.projectKeys.isEmpty else { return [] }
        let match: String
        do { match = try Self.safeFTSQuery(query) }
        catch { throw SQLCipherVaultError.emptyDocumentQuery }
        let boundedLimit = min(max(limit, 1), 100)
        let (projectClause, projectBinds) = Self.projectFilter(
            authorization.projectKeys,
            firstParameter: 3
        )
        let limitParameter = 3 + projectBinds.count
        let generation = try connection.scalarInteger(
            "SELECT generation FROM retrieval_state WHERE name = 'document-fts';"
        ) ?? 0
        let indexGeneration = "fts5-bm25-v1:" + String(generation)
        let rows = try connection.rows(
            """
            WITH matching_chunks AS (
                SELECT d.document_id, d.project_key, d.sensitivity, d.title,
                       c.heading, c.content, c.ordinal, c.id AS chunk_id,
                       bm25(document_chunk_fts, 8.0, 3.0, 1.0) AS raw_rank,
                       d.plaintext_sha256, d.library_path, d.origins_json,
                       d.observed_at_ms, d.modified_at_ms, d.evidence_status
                FROM document_chunk_fts
                JOIN document_chunks c ON c.id = document_chunk_fts.rowid
                JOIN documents d ON d.document_id = c.document_id
                WHERE document_chunk_fts MATCH ?1
                  AND d.sensitivity_rank <= ?2
                  AND d.review_state = 'approved'
                  AND d.project_key IN (\(projectClause))
            ), ranked_documents AS (
                SELECT *, row_number() OVER (
                    PARTITION BY document_id ORDER BY raw_rank ASC, chunk_id ASC
                ) AS document_rank
                FROM matching_chunks
            )
            SELECT document_id, project_key, sensitivity, title, heading,
                   content, ordinal, raw_rank, plaintext_sha256, library_path,
                   origins_json, observed_at_ms, modified_at_ms, evidence_status
            FROM ranked_documents
            WHERE document_rank = 1
            ORDER BY raw_rank ASC, chunk_id ASC
            LIMIT ?\(limitParameter);
            """,
            binds: [
                .text(match),
                .integer(Int64(authorization.maximumSensitivity.policyRank)),
            ] + projectBinds + [.integer(Int64(boundedLimit))]
        )
        return try rows.map { row in
            guard let documentID = row[safe: 0]?.textValue,
                  let projectKey = row[safe: 1]?.textValue,
                  let sensitivityText = row[safe: 2]?.textValue,
                  let sensitivity = ResearchSensitivity(rawValue: sensitivityText),
                  let title = row[safe: 3]?.textValue,
                  let content = row[safe: 5]?.textValue,
                  let ordinal = row[safe: 6]?.integerValue,
                  let rawScore = row[safe: 7]?.doubleValue,
                  let hash = row[safe: 8]?.textValue,
                  let libraryPath = row[safe: 9]?.textValue,
                  let originsData = row[safe: 10]?.blobValue,
                  let observedAt = row[safe: 11]?.integerValue,
                  let modifiedAt = row[safe: 12]?.integerValue else {
                throw SQLCipherVaultError.corruptSchema
            }
            let origins = try decoder.decode([String].self, from: originsData)
            let evidenceStatus = row[safe: 13]?.textValue.flatMap(ResearchEvidenceStatus.init)
            return ResearchDocumentSearchHit(
                documentID: documentID,
                projectKey: projectKey,
                sensitivity: sensitivity,
                title: title,
                heading: row[safe: 4]?.textValue,
                content: content,
                ordinal: Int(ordinal),
                score: -rawScore,
                plaintextSHA256: hash,
                libraryPath: libraryPath,
                origins: origins,
                observedAt: Self.date(milliseconds: observedAt),
                sourceModifiedAt: Self.date(milliseconds: modifiedAt),
                evidenceStatus: evidenceStatus,
                indexGeneration: indexGeneration
            )
        }
    }

    public func verifyIntegrity() throws -> SQLCipherIntegrityEvidence {
        let schemaVersion = Int(try connection.scalarInteger("PRAGMA user_version;") ?? -1)
        let cipherVersion = try connection.scalarText("PRAGMA cipher_version;") ?? ""
        let receiptCount = Int(try connection.scalarInteger("SELECT count(*) FROM receipts;") ?? -1)
        let documentCount = Int(try connection.scalarInteger("SELECT count(*) FROM documents;") ?? -1)
        let chunkCount = Int(try connection.scalarInteger("SELECT count(*) FROM document_chunks;") ?? -1)
        let quickCheckPassed = try connection.scalarText("PRAGMA quick_check;") == "ok"
        let cipherIntegrityPassed = try connection.rows("PRAGMA cipher_integrity_check;").isEmpty
        let foreignKeysPassed = try connection.rows("PRAGMA foreign_key_check;").isEmpty
        let evidence = SQLCipherIntegrityEvidence(
            schemaVersion: schemaVersion,
            cipherVersion: cipherVersion,
            receiptCount: receiptCount,
            documentCount: documentCount,
            chunkCount: chunkCount,
            quickCheckPassed: quickCheckPassed,
            cipherIntegrityPassed: cipherIntegrityPassed,
            foreignKeysPassed: foreignKeysPassed
        )
        guard
            schemaVersion == Self.currentSchemaVersion,
            !cipherVersion.isEmpty,
            receiptCount >= 0,
            documentCount >= 0,
            chunkCount >= 0,
            quickCheckPassed,
            cipherIntegrityPassed,
            foreignKeysPassed
        else {
            throw SQLCipherVaultError.integrityFailure
        }
        return evidence
    }

    public func createBackup(at destination: URL, backupKey: Data) throws -> SQLCipherBackupEvidence {
        guard backupKey.count == 32 else { throw SQLCipherBackupError.invalidKeyLength }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw SQLCipherBackupError.destinationExists
        }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let staging = parent.appendingPathComponent(
            "." + destination.lastPathComponent + ".partial-" + UUID().uuidString
        )
        defer { Self.removeStagingFiles(staging) }

        _ = try connection.rows("PRAGMA wal_checkpoint(TRUNCATE);")
        try connection.backup(to: staging.path, key: backupKey)
        let evidence = try Self.validateBackup(at: staging, key: backupKey)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: staging.path
        )
        try FileManager.default.moveItem(at: staging, to: destination)
        return evidence
    }

    public static func restoreBackup(
        from backup: URL,
        backupKey: Data,
        to destination: URL,
        destinationKey: Data
    ) throws -> SQLCipherBackupEvidence {
        guard backupKey.count == 32, destinationKey.count == 32 else {
            throw SQLCipherBackupError.invalidKeyLength
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw SQLCipherBackupError.destinationExists
        }
        _ = try validateBackup(at: backup, key: backupKey)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let staging = parent.appendingPathComponent(
            "." + destination.lastPathComponent + ".partial-" + UUID().uuidString
        )
        defer { removeStagingFiles(staging) }

        let source = try SQLCipherConnection(path: backup.path, key: backupKey, readOnly: true)
        try source.backup(to: staging.path, key: destinationKey)
        source.close()
        let evidence = try validateBackup(at: staging, key: destinationKey)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: staging.path
        )
        try FileManager.default.moveItem(at: staging, to: destination)
        return evidence
    }

    private func decodeAndValidate(_ payload: Data) throws -> ResearchReceipt {
        let receipt = try decoder.decode(ResearchReceipt.self, from: payload)
        try ResearchReceiptValidator.validate(receipt)
        return receipt
    }

    private static func migrate(_ connection: SQLCipherConnection) throws {
        let current = Int(try connection.scalarInteger("PRAGMA user_version;") ?? 0)
        guard current <= Self.currentSchemaVersion else {
            throw SQLCipherVaultError.unsupportedSchemaVersion(current)
        }
        if current == 0 {
            try connection.transaction {
            try connection.execute(
                """
                CREATE TABLE receipts(
                    receipt_id TEXT PRIMARY KEY NOT NULL,
                    project_key TEXT NOT NULL,
                    sensitivity TEXT NOT NULL,
                    sensitivity_rank INTEGER NOT NULL CHECK(sensitivity_rank BETWEEN 0 AND 3),
                    created_at_ms INTEGER NOT NULL,
                    content_hash TEXT NOT NULL UNIQUE CHECK(length(content_hash) = 64),
                    payload BLOB NOT NULL
                );
                """
            )
            try connection.execute(
                """
                CREATE TABLE sources(
                    receipt_id TEXT NOT NULL REFERENCES receipts(receipt_id) ON DELETE CASCADE,
                    source_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    locator TEXT NOT NULL,
                    observed_at_ms INTEGER NOT NULL,
                    plaintext_sha256 TEXT NOT NULL CHECK(length(plaintext_sha256) = 64),
                    PRIMARY KEY(receipt_id, source_id)
                ) WITHOUT ROWID;
                """
            )
            try connection.execute(
                """
                CREATE TABLE findings(
                    id INTEGER PRIMARY KEY,
                    receipt_id TEXT NOT NULL REFERENCES receipts(receipt_id) ON DELETE CASCADE,
                    claim TEXT NOT NULL,
                    status TEXT NOT NULL
                );
                """
            )
            try connection.execute(
                """
                CREATE TABLE finding_evidence(
                    finding_id INTEGER NOT NULL REFERENCES findings(id) ON DELETE CASCADE,
                    receipt_id TEXT NOT NULL,
                    source_id TEXT NOT NULL,
                    PRIMARY KEY(finding_id, source_id),
                    FOREIGN KEY(receipt_id, source_id)
                        REFERENCES sources(receipt_id, source_id) ON DELETE CASCADE
                ) WITHOUT ROWID;
                """
            )
            try connection.execute(
                """
                CREATE VIRTUAL TABLE finding_fts USING fts5(
                    claim,
                    content='findings',
                    content_rowid='id',
                    tokenize='unicode61 remove_diacritics 2'
                );
                """
            )
            try connection.execute(
                """
                CREATE TRIGGER findings_after_insert AFTER INSERT ON findings BEGIN
                    INSERT INTO finding_fts(rowid, claim) VALUES (new.id, new.claim);
                END;
                """
            )
            try connection.execute(
                """
                CREATE TRIGGER findings_after_delete AFTER DELETE ON findings BEGIN
                    INSERT INTO finding_fts(finding_fts, rowid, claim)
                    VALUES ('delete', old.id, old.claim);
                END;
                """
            )
            try connection.execute(
                """
                CREATE TRIGGER findings_after_update AFTER UPDATE ON findings BEGIN
                    INSERT INTO finding_fts(finding_fts, rowid, claim)
                    VALUES ('delete', old.id, old.claim);
                    INSERT INTO finding_fts(rowid, claim) VALUES (new.id, new.claim);
                END;
                """
            )
            try connection.execute(
                "CREATE INDEX receipts_scope ON receipts(project_key, sensitivity_rank, created_at_ms);"
            )
            try connection.execute("CREATE INDEX findings_receipt ON findings(receipt_id);")
                try connection.execute("PRAGMA user_version = 1;")
            }
        }

        let afterV1 = Int(try connection.scalarInteger("PRAGMA user_version;") ?? 0)
        if afterV1 == 1 {
            try connection.transaction {
                try connection.execute(
                    """
                    CREATE TABLE documents(
                        document_id TEXT PRIMARY KEY NOT NULL,
                        project_key TEXT NOT NULL,
                        sensitivity TEXT NOT NULL,
                        sensitivity_rank INTEGER NOT NULL CHECK(sensitivity_rank BETWEEN 0 AND 3),
                        title TEXT NOT NULL,
                        category TEXT NOT NULL,
                        library_path TEXT NOT NULL,
                        origins_json BLOB NOT NULL,
                        content TEXT NOT NULL,
                        plaintext_sha256 TEXT NOT NULL CHECK(length(plaintext_sha256) = 64),
                        byte_count INTEGER NOT NULL CHECK(byte_count >= 0),
                        modified_at_ms INTEGER NOT NULL
                    );
                    """
                )
                try connection.execute(
                    """
                    CREATE TABLE document_chunks(
                        id INTEGER PRIMARY KEY,
                        document_id TEXT NOT NULL REFERENCES documents(document_id) ON DELETE CASCADE,
                        ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
                        title TEXT NOT NULL,
                        heading TEXT,
                        content TEXT NOT NULL,
                        approximate_token_count INTEGER NOT NULL CHECK(approximate_token_count > 0),
                        UNIQUE(document_id, ordinal)
                    );
                    """
                )
                try connection.execute(
                    """
                    CREATE VIRTUAL TABLE document_chunk_fts USING fts5(
                        title, heading, content,
                        content='document_chunks', content_rowid='id',
                        tokenize='unicode61 remove_diacritics 2'
                    );
                    """
                )
                try connection.execute(
                    """
                    CREATE TRIGGER document_chunks_after_insert AFTER INSERT ON document_chunks BEGIN
                        INSERT INTO document_chunk_fts(rowid, title, heading, content)
                        VALUES (new.id, new.title, new.heading, new.content);
                    END;
                    """
                )
                try connection.execute(
                    """
                    CREATE TRIGGER document_chunks_after_delete AFTER DELETE ON document_chunks BEGIN
                        INSERT INTO document_chunk_fts(document_chunk_fts, rowid, title, heading, content)
                        VALUES ('delete', old.id, old.title, old.heading, old.content);
                    END;
                    """
                )
                try connection.execute(
                    """
                    CREATE TRIGGER document_chunks_after_update AFTER UPDATE ON document_chunks BEGIN
                        INSERT INTO document_chunk_fts(document_chunk_fts, rowid, title, heading, content)
                        VALUES ('delete', old.id, old.title, old.heading, old.content);
                        INSERT INTO document_chunk_fts(rowid, title, heading, content)
                        VALUES (new.id, new.title, new.heading, new.content);
                    END;
                    """
                )
                try connection.execute(
                    "CREATE INDEX documents_scope ON documents(project_key, sensitivity_rank, modified_at_ms);"
                )
                try connection.execute(
                    "CREATE INDEX document_chunks_document ON document_chunks(document_id, ordinal);"
                )
                try connection.execute("PRAGMA user_version = 2;")
            }
        }

        let afterV2 = Int(try connection.scalarInteger("PRAGMA user_version;") ?? 0)
        if afterV2 == 2 {
            try connection.transaction {
                // Existing v2 imports did not record their ingestion time. The
                // source modification time is a conservative migration value;
                // a fresh re-import will populate an exact observation time.
                try connection.execute(
                    "ALTER TABLE documents ADD COLUMN observed_at_ms INTEGER NOT NULL DEFAULT 0;"
                )
                try connection.execute(
                    "UPDATE documents SET observed_at_ms = modified_at_ms WHERE observed_at_ms = 0;"
                )
                try connection.execute(
                    "ALTER TABLE documents ADD COLUMN evidence_status TEXT;"
                )
                try connection.execute(
                    """
                    CREATE TABLE retrieval_state(
                        name TEXT PRIMARY KEY NOT NULL,
                        generation INTEGER NOT NULL CHECK(generation >= 0)
                    ) WITHOUT ROWID;
                    """
                )
                try connection.execute(
                    """
                    INSERT INTO retrieval_state(name, generation)
                    VALUES ('document-fts', (SELECT count(*) FROM documents));
                    """
                )
                try connection.execute(
                    """
                    CREATE TRIGGER documents_generation_after_insert
                    AFTER INSERT ON documents BEGIN
                        UPDATE retrieval_state SET generation = generation + 1
                        WHERE name = 'document-fts';
                    END;
                    """
                )
                try connection.execute(
                    """
                    CREATE TRIGGER documents_generation_after_delete
                    AFTER DELETE ON documents BEGIN
                        UPDATE retrieval_state SET generation = generation + 1
                        WHERE name = 'document-fts';
                    END;
                    """
                )
                try connection.execute("PRAGMA user_version = 3;")
            }
        }

        let afterV3 = Int(try connection.scalarInteger("PRAGMA user_version;") ?? 0)
        if afterV3 == 3 {
            try connection.transaction {
                try connection.execute(
                    "ALTER TABLE receipts ADD COLUMN review_state TEXT NOT NULL DEFAULT 'approved' CHECK(review_state IN ('quarantined','approved'));"
                )
                try connection.execute(
                    "ALTER TABLE documents ADD COLUMN review_state TEXT NOT NULL DEFAULT 'approved' CHECK(review_state IN ('quarantined','approved'));"
                )
                try connection.execute(
                    "CREATE INDEX receipts_review ON receipts(review_state, project_key);"
                )
                try connection.execute(
                    "CREATE INDEX documents_review ON documents(review_state, project_key);"
                )
                try connection.execute("PRAGMA user_version = 4;")
            }
        }

        let afterV4 = Int(try connection.scalarInteger("PRAGMA user_version;") ?? 0)
        if afterV4 == 4 {
            try connection.transaction {
                try connection.execute(
                    """
                    CREATE TABLE reasoning_generations(
                        name TEXT PRIMARY KEY NOT NULL,
                        base_generation INTEGER NOT NULL CHECK(base_generation >= 0),
                        rule_pack_hash TEXT NOT NULL,
                        engine_version TEXT NOT NULL,
                        rules_json BLOB NOT NULL
                    ) WITHOUT ROWID;
                    """
                )
                try connection.execute(
                    "INSERT INTO reasoning_generations(name, base_generation, rule_pack_hash, engine_version, rules_json) VALUES ('active', 0, '', '', X'5b5d');"
                )
                try connection.execute(
                    """
                    CREATE TABLE reasoning_base_facts(
                        fact_id TEXT PRIMARY KEY NOT NULL CHECK(length(fact_id) = 64),
                        project_key TEXT NOT NULL,
                        predicate TEXT NOT NULL,
                        sensitivity_rank INTEGER NOT NULL CHECK(sensitivity_rank BETWEEN 0 AND 3),
                        payload BLOB NOT NULL
                    );
                    """
                )
                try connection.execute(
                    "CREATE INDEX reasoning_base_scope ON reasoning_base_facts(project_key, sensitivity_rank, predicate);"
                )
                try connection.execute(
                    """
                    CREATE TABLE reasoning_fact_evidence(
                        fact_id TEXT NOT NULL REFERENCES reasoning_base_facts(fact_id) ON DELETE CASCADE,
                        receipt_id TEXT NOT NULL,
                        source_id TEXT NOT NULL,
                        PRIMARY KEY(fact_id, receipt_id, source_id),
                        FOREIGN KEY(receipt_id, source_id)
                            REFERENCES sources(receipt_id, source_id) ON DELETE RESTRICT
                    ) WITHOUT ROWID;
                    """
                )
                try connection.execute(
                    """
                    CREATE TABLE reasoning_derived_cache(
                        fact_id TEXT PRIMARY KEY NOT NULL CHECK(length(fact_id) = 64),
                        project_key TEXT NOT NULL,
                        sensitivity_rank INTEGER NOT NULL CHECK(sensitivity_rank BETWEEN 0 AND 3),
                        base_generation INTEGER NOT NULL CHECK(base_generation >= 0),
                        rule_pack_hash TEXT NOT NULL CHECK(length(rule_pack_hash) = 64),
                        engine_version TEXT NOT NULL,
                        payload BLOB NOT NULL
                    );
                    """
                )
                try connection.execute(
                    "CREATE INDEX reasoning_cache_scope ON reasoning_derived_cache(project_key, sensitivity_rank);"
                )
                try connection.execute(
                    """
                    CREATE TABLE reasoning_derivations(
                        conclusion_fact_id TEXT NOT NULL REFERENCES reasoning_derived_cache(fact_id) ON DELETE CASCADE,
                        rule_id TEXT NOT NULL,
                        premise_fact_ids_json BLOB NOT NULL,
                        PRIMARY KEY(conclusion_fact_id, rule_id, premise_fact_ids_json)
                    ) WITHOUT ROWID;
                    """
                )
                try connection.execute("PRAGMA user_version = 5;")
            }
        }

        let afterV5 = Int(try connection.scalarInteger("PRAGMA user_version;") ?? 0)
        if afterV5 == 5 {
            try connection.transaction {
                try connection.execute(
                    """
                    CREATE TABLE spaces(
                        space_id TEXT PRIMARY KEY NOT NULL,
                        name TEXT NOT NULL,
                        kind TEXT NOT NULL CHECK(kind IN ('portfolio','project')),
                        created_at_ms INTEGER NOT NULL
                    ) WITHOUT ROWID;
                    """
                )
                try connection.execute(
                    """
                    CREATE TABLE space_project_keys(
                        space_id TEXT NOT NULL REFERENCES spaces(space_id) ON DELETE CASCADE,
                        project_key TEXT NOT NULL,
                        PRIMARY KEY(space_id, project_key)
                    ) WITHOUT ROWID;
                    """
                )
                try connection.execute(
                    "INSERT INTO spaces(space_id, name, kind, created_at_ms) VALUES ('portfolio', 'Portfolio', 'portfolio', 0);"
                )
                try connection.execute(
                    """
                    INSERT OR IGNORE INTO spaces(space_id, name, kind, created_at_ms)
                    SELECT 'project:' || project_key, project_key, 'project', 0
                    FROM (
                        SELECT project_key FROM receipts
                        UNION SELECT project_key FROM documents
                        UNION SELECT project_key FROM reasoning_base_facts
                    );
                    """
                )
                try connection.execute(
                    """
                    INSERT OR IGNORE INTO space_project_keys(space_id, project_key)
                    SELECT 'project:' || project_key, project_key
                    FROM (
                        SELECT project_key FROM receipts
                        UNION SELECT project_key FROM documents
                        UNION SELECT project_key FROM reasoning_base_facts
                    );
                    """
                )
                try connection.execute(
                    """
                    INSERT OR IGNORE INTO space_project_keys(space_id, project_key)
                    SELECT 'portfolio', project_key
                    FROM (
                        SELECT project_key FROM receipts
                        UNION SELECT project_key FROM documents
                        UNION SELECT project_key FROM reasoning_base_facts
                    );
                    """
                )
                try connection.execute(
                    "CREATE INDEX space_project_lookup ON space_project_keys(project_key, space_id);"
                )
                try connection.execute(
                    """
                    CREATE TRIGGER spaces_after_receipt_insert AFTER INSERT ON receipts BEGIN
                        INSERT OR IGNORE INTO spaces(space_id, name, kind, created_at_ms)
                        VALUES ('project:' || new.project_key, new.project_key, 'project', new.created_at_ms);
                        INSERT OR IGNORE INTO space_project_keys(space_id, project_key)
                        VALUES ('project:' || new.project_key, new.project_key);
                        INSERT OR IGNORE INTO space_project_keys(space_id, project_key)
                        VALUES ('portfolio', new.project_key);
                    END;
                    """
                )
                try connection.execute(
                    """
                    CREATE TRIGGER spaces_after_document_insert AFTER INSERT ON documents BEGIN
                        INSERT OR IGNORE INTO spaces(space_id, name, kind, created_at_ms)
                        VALUES ('project:' || new.project_key, new.project_key, 'project', new.observed_at_ms);
                        INSERT OR IGNORE INTO space_project_keys(space_id, project_key)
                        VALUES ('project:' || new.project_key, new.project_key);
                        INSERT OR IGNORE INTO space_project_keys(space_id, project_key)
                        VALUES ('portfolio', new.project_key);
                    END;
                    """
                )
                try connection.execute("PRAGMA user_version = 6;")
            }
        }
    }

    private static func projectFilter(
        _ projects: Set<String>,
        firstParameter: Int
    ) -> (String, [SQLCipherBind]) {
        let sorted = projects.sorted()
        let placeholders = sorted.indices.map { "?" + String(firstParameter + $0) }
        return (placeholders.joined(separator: ", "), sorted.map(SQLCipherBind.text))
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
    private static let ftsStopwords: Set<String> = [
        // French
        "ai", "ait", "alors", "au", "aussi", "autre", "aux", "avec", "avoir",
        "avais", "avait", "beaucoup", "bien", "car", "ce", "cela", "ces", "cet",
        "cette", "ceux", "chez", "comme", "coup", "dans", "de", "deja", "des",
        "donc", "dont", "du", "elle", "elles", "en", "encore", "entre", "est",
        "et", "etait", "etc", "etre", "eu", "faire", "fait", "faut", "genre",
        "ici", "il", "ils", "je", "la", "le", "les", "leur", "lui", "ma", "mais",
        "me", "meme", "mes", "moi", "mon", "ne", "ni", "nos", "notre", "nous",
        "on", "ont", "ou", "par", "parce", "pas", "peu", "peut", "plus", "pour",
        "pourquoi", "quand", "que", "quel", "quelle", "qui", "quoi", "sa",
        "sans", "se", "ses", "si", "sinon", "sur", "ta", "te", "tes", "toi",
        "ton", "tous", "tout", "toute", "toutes", "tres", "tu", "un", "une",
        "va", "vais", "vers", "veut", "veux", "voir", "vos", "votre", "vous",
        // English
        "about", "all", "also", "am", "an", "and", "any", "are", "as", "at",
        "be", "been", "but", "by", "can", "could", "did", "do", "does", "for",
        "from", "get", "had", "has", "have", "how", "if", "in", "is", "it",
        "its", "just", "like", "more", "my", "no", "not", "of", "one", "or",
        "our", "out", "should", "so", "some", "that", "the", "their", "them",
        "then", "there", "these", "they", "this", "to", "too", "up", "us",
        "was", "we", "were", "what", "when", "where", "which", "who", "why",
        "will", "with", "would", "you", "your",
    ]

    private static func safeFTSQuery(_ query: String) throws -> String {
        let tokens = query
            .split { !$0.isLetter && !$0.isNumber }
            .prefix(32)
            .map { String($0.prefix(64)).lowercased() }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { throw ClaimSearchError.emptyQuery }
        // Keep the function words only when nothing else is left: an empty
        // query would return nothing at all, which is worse than a noisy match.
        let content = tokens.filter { !ftsStopwords.contains($0) }
        let effective = content.isEmpty ? tokens : content
        return effective.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " OR ")
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    private static func validateBackup(at url: URL, key: Data) throws -> SQLCipherBackupEvidence {
        let validation = try SQLCipherConnection(path: url.path, key: key, readOnly: true)
        defer { validation.close() }
        let schemaVersion = Int(try validation.scalarInteger("PRAGMA user_version;") ?? -1)
        let cipherVersion = try validation.scalarText("PRAGMA cipher_version;") ?? ""
        let receiptCount = Int(try validation.scalarInteger("SELECT count(*) FROM receipts;") ?? -1)
        let documentCount = Int(try validation.scalarInteger("SELECT count(*) FROM documents;") ?? -1)
        let chunkCount = Int(try validation.scalarInteger("SELECT count(*) FROM document_chunks;") ?? -1)
        let quickCheck = try validation.scalarText("PRAGMA quick_check;") == "ok"
        let cipherIntegrity = try validation.rows("PRAGMA cipher_integrity_check;").isEmpty
        let foreignKeys = try validation.rows("PRAGMA foreign_key_check;").isEmpty
        guard
            schemaVersion == currentSchemaVersion,
            !cipherVersion.isEmpty,
            receiptCount >= 0,
            documentCount >= 0,
            chunkCount >= 0,
            quickCheck,
            cipherIntegrity,
            foreignKeys
        else {
            throw SQLCipherBackupError.verificationFailed
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard byteCount > 0 else { throw SQLCipherBackupError.verificationFailed }
        return SQLCipherBackupEvidence(
            schemaVersion: schemaVersion,
            cipherVersion: cipherVersion,
            receiptCount: receiptCount,
            documentCount: documentCount,
            chunkCount: chunkCount,
            byteCount: byteCount,
            ciphertextSHA256: try sha256(of: url)
        )
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func removeStagingFiles(_ database: URL) {
        let manager = FileManager.default
        for url in [
            database,
            URL(fileURLWithPath: database.path + "-wal"),
            URL(fileURLWithPath: database.path + "-shm"),
        ] where manager.fileExists(atPath: url.path) {
            try? manager.removeItem(at: url)
        }
    }
}

private extension SQLCipherValue {
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

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
