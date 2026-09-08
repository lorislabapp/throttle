import CryptoKit
import Foundation
import ResearchVaultIngestion
import ResearchVaultModel
import ResearchVaultReasoning
import ResearchVaultStore

extension SQLCipherReceiptStore {

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
}
