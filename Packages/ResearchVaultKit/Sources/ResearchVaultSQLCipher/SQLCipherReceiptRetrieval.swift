import Foundation
import ResearchVaultModel

public struct ResearchReceiptSearchHit: Sendable {
    public let receipt: ResearchReceipt
    public let findingIndex: Int
    public let score: Double
}

extension SQLCipherReceiptStore {
    /// Best finding per approved receipt. Authorization and review state filter
    /// in SQL, before sealed payloads are returned; duplicate claims retain their
    /// exact ordinal and evidence links instead of matching by text afterwards.
    public func searchReceiptDocuments(
        query: String,
        limit: Int,
        authorization: VaultAuthorization
    ) throws -> [ResearchReceiptSearchHit] {
        guard !authorization.projectKeys.isEmpty else { return [] }
        let match = try Self.safeFTSQuery(query)
        let (projects, projectBinds) = Self.projectFilter(authorization.projectKeys, firstParameter: 3)
        let limitParameter = 3 + projectBinds.count
        let rows = try connection.rows(
            """
            WITH matching AS (
                SELECT r.receipt_id, f.id AS finding_id, bm25(finding_fts) AS raw_rank
                FROM finding_fts
                JOIN findings f ON f.id = finding_fts.rowid
                JOIN receipts r ON r.receipt_id = f.receipt_id
                WHERE finding_fts MATCH ?1 AND r.sensitivity_rank <= ?2
                  AND r.review_state = 'approved' AND r.project_key IN (\(projects))
            ), ranked AS (
                SELECT *, ROW_NUMBER() OVER (
                    PARTITION BY receipt_id ORDER BY raw_rank ASC, finding_id ASC
                ) AS receipt_rank FROM matching
            )
            SELECT r.payload, (
                SELECT count(*) FROM findings preceding
                WHERE preceding.receipt_id = ranked.receipt_id AND preceding.id < ranked.finding_id
            ), ranked.raw_rank
            FROM ranked JOIN receipts r ON r.receipt_id = ranked.receipt_id
            WHERE receipt_rank = 1
            ORDER BY raw_rank ASC, finding_id ASC LIMIT ?\(limitParameter);
            """,
            binds: [.text(match), .integer(Int64(authorization.maximumSensitivity.policyRank))]
                + projectBinds + [.integer(Int64(min(max(limit, 1), 20)))]
        )
        return try rows.map { row in
            guard row.count == 3, let payload = row[0].blobValue,
                  let ordinal = row[1].integerValue, let rank = row[2].doubleValue else {
                throw SQLCipherVaultError.corruptSchema
            }
            let receipt = try decodeAndValidate(payload)
            guard receipt.findings.indices.contains(Int(ordinal)) else { throw SQLCipherVaultError.corruptSchema }
            return ResearchReceiptSearchHit(receipt: receipt, findingIndex: Int(ordinal), score: -rank)
        }
    }
}
