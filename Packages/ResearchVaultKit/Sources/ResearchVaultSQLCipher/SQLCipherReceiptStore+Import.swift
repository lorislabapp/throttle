import CryptoKit
import Foundation
import ResearchVaultIngestion
import ResearchVaultModel
import ResearchVaultReasoning
import ResearchVaultStore

extension SQLCipherReceiptStore {

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

    func insertValidatedReceipt(
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

        try insertSourcesAndFindings(receipt)
    }

    private func insertSourcesAndFindings(_ receipt: ResearchReceipt) throws {
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
}
