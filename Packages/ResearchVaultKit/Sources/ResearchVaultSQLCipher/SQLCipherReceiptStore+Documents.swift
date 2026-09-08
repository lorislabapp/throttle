import CryptoKit
import Foundation
import ResearchVaultIngestion
import ResearchVaultModel
import ResearchVaultReasoning
import ResearchVaultStore

extension SQLCipherReceiptStore {

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
}
