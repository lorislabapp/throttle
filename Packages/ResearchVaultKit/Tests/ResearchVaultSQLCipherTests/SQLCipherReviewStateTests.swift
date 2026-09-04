import CryptoKit
import Foundation
import ResearchVaultIngestion
import ResearchVaultModel
import ResearchVaultStore
import ResearchVaultSQLCipher
import SQLCipher
import XCTest

final class SQLCipherReviewStateTests: XCTestCase {
    func testQuarantinedReceiptIsInvisibleToSearchAndReads() async throws {
        let (database, key) = try databaseFixture("quarantined")
        let store = try SQLCipherReceiptStore(databaseURL: database, key: key)
        let receipt = try makeReceipt(claim: "quarantine sentinel")
        let authorization = fullAuthorization()

        _ = try await store.importReceipts(
            [receipt],
            authorization: authorization,
            reviewState: .quarantined
        )

        let hits = try await store.searchClaims(
            query: "quarantine sentinel",
            authorization: authorization
        )
        let stored = try await store.receipt(id: receipt.receiptID, authorization: authorization)
        let receipts = try await store.receipts(authorization: authorization)
        XCTAssertTrue(hits.isEmpty)
        XCTAssertNil(stored)
        XCTAssertTrue(receipts.isEmpty)
    }

    func testApprovedReceiptIsVisible() async throws {
        let (database, key) = try databaseFixture("approved")
        let store = try SQLCipherReceiptStore(databaseURL: database, key: key)
        let receipt = try makeReceipt(claim: "approved sentinel")
        let authorization = fullAuthorization()

        _ = try await store.importReceipts(
            [receipt],
            authorization: authorization,
            reviewState: .approved
        )

        let hits = try await store.searchClaims(
            query: "approved sentinel",
            authorization: authorization
        )
        let stored = try await store.receipt(
            id: receipt.receiptID,
            authorization: authorization
        )
        XCTAssertEqual(hits.map(\.receiptID), [receipt.receiptID])
        XCTAssertEqual(stored, receipt)
    }

    func testQuarantinedDocumentIsInvisibleToSearch() async throws {
        let (database, key) = try databaseFixture("document-quarantined")
        let store = try SQLCipherReceiptStore(databaseURL: database, key: key)
        let authorization = fullAuthorization()
        let document = makeDocument(text: "document quarantine sentinel")

        _ = try await store.importDocument(
            document,
            authorization: authorization,
            reviewState: .quarantined
        )

        let hits = try await store.searchDocuments(
            query: "document quarantine",
            authorization: authorization
        )
        XCTAssertTrue(hits.isEmpty)
    }

    func testV3DatabaseMigratesExistingRowsAsApproved() async throws {
        let (database, key) = try databaseFixture("migration")
        let authorization = fullAuthorization()
        let receipt = try makeReceipt(claim: "migration receipt sentinel")
        let document = makeDocument(text: "migration document sentinel")

        do {
            let store = try SQLCipherReceiptStore(databaseURL: database, key: key)
            _ = try await store.importReceipt(
                receipt,
                authorization: authorization,
                reviewState: .approved
            )
            _ = try await store.importDocument(
                document,
                authorization: authorization,
                reviewState: .approved
            )
            await store.close()
        }

        try downgradeToV3(database: database, key: key)

        let reopened = try SQLCipherReceiptStore(databaseURL: database, key: key)
        let receiptHits = try await reopened.searchClaims(
            query: "migration receipt",
            authorization: authorization
        )
        let documentHits = try await reopened.searchDocuments(
            query: "migration document",
            authorization: authorization
        )
        let integrity = try await reopened.verifyIntegrity()
        XCTAssertEqual(integrity.schemaVersion, SQLCipherReceiptStore.currentSchemaVersion)
        XCTAssertEqual(receiptHits.map(\.receiptID), [receipt.receiptID])
        XCTAssertEqual(documentHits.map(\.documentID), [document.documentID])
    }

    func testQuarantineListShowsPendingOnlyWithinAuthorization() async throws {
        let (database, key) = try databaseFixture("list")
        let store = try SQLCipherReceiptStore(databaseURL: database, key: key)
        let pending = try makeReceipt(claim: "pending list sentinel")
        let approved = try makeReceipt(claim: "already approved sentinel")
        let authorization = fullAuthorization()
        _ = try await store.importReceipt(
            pending,
            authorization: authorization,
            reviewState: .quarantined
        )
        _ = try await store.importReceipt(
            approved,
            authorization: authorization,
            reviewState: .approved
        )

        let items = try await store.quarantinedReceipts(authorization: authorization)
        XCTAssertEqual(items.map(\.receiptID), [pending.receiptID])
        XCTAssertEqual(items.first?.question, "pending list sentinel")
        XCTAssertEqual(items.first?.sourceCount, 1)
        XCTAssertEqual(items.first?.firstSourceLocator, "/tmp/" + pending.receiptID + ".md")
    }

    func testApproveMakesReceiptSearchableAndIsIdempotent() async throws {
        let (database, key) = try databaseFixture("approve")
        let store = try SQLCipherReceiptStore(databaseURL: database, key: key)
        let receipt = try makeReceipt(claim: "approve flow sentinel")
        let authorization = fullAuthorization()
        _ = try await store.importReceipt(
            receipt,
            authorization: authorization,
            reviewState: .quarantined
        )

        let firstApproval = try await store.approveReceipts(ids: [receipt.receiptID])
        let secondApproval = try await store.approveReceipts(ids: [receipt.receiptID])
        XCTAssertEqual(firstApproval, 1)
        XCTAssertEqual(secondApproval, 0)
        let hits = try await store.searchClaims(
            query: "approve flow",
            authorization: authorization
        )
        XCTAssertEqual(hits.map(\.receiptID), [receipt.receiptID])
    }

    func testRejectDeletesReceiptAndAllowsReimport() async throws {
        let (database, key) = try databaseFixture("reject")
        let store = try SQLCipherReceiptStore(databaseURL: database, key: key)
        let receipt = try makeReceipt(claim: "reject flow sentinel")
        let authorization = fullAuthorization()
        _ = try await store.importReceipt(
            receipt,
            authorization: authorization,
            reviewState: .quarantined
        )

        let firstRejection = try await store.rejectReceipts(ids: [receipt.receiptID])
        let secondRejection = try await store.rejectReceipts(ids: [receipt.receiptID])
        let remaining = try await store.quarantinedReceipts(authorization: authorization)
        XCTAssertEqual(firstRejection, 1)
        XCTAssertEqual(secondRejection, 0)
        XCTAssertTrue(remaining.isEmpty)
        let reimport = try await store.importReceipt(
            receipt,
            authorization: authorization,
            reviewState: .quarantined
        )
        XCTAssertEqual(reimport, .inserted)
    }

    private func fullAuthorization() -> VaultAuthorization {
        VaultAuthorization(projectKeys: ["throttle"], maximumSensitivity: .restricted)
    }

    private func makeReceipt(claim: String) throws -> ResearchReceipt {
        let receiptID = UUID().uuidString.lowercased()
        let sourceID = "source-" + receiptID
        return try ResearchReceipt.seal(
            receiptID: receiptID,
            sessionID: "review-state-test",
            agentID: "review-state-test",
            projectKey: "throttle",
            question: claim,
            findings: [
                ResearchFinding(claim: claim, status: .supported, evidenceIDs: [sourceID]),
            ],
            sources: [
                ResearchSource(
                    id: sourceID,
                    kind: .file,
                    locator: "/tmp/" + receiptID + ".md",
                    observedAt: Date(timeIntervalSince1970: 1_787_832_000),
                    sha256: String(repeating: "a", count: 64)
                ),
            ],
            sensitivity: .internal,
            createdAt: Date(timeIntervalSince1970: 1_787_832_000)
        )
    }

    private func makeDocument(text: String) -> ResearchDocumentCandidate {
        let bytes = Data(text.utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return ResearchDocumentCandidate(
            documentID: "dr-" + UUID().uuidString.lowercased(),
            title: "Review state document",
            projectKey: "throttle",
            category: "test",
            libraryPath: "library/test/throttle/review-state.md",
            origins: ["/tmp/review-state.md"],
            content: text,
            plaintextSHA256: hash,
            byteCount: bytes.count,
            modifiedAt: Date(timeIntervalSince1970: 1_787_832_000),
            sensitivity: .internal
        )
    }

    private func databaseFixture(_ suffix: String) throws -> (URL, Data) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ResearchVaultReviewState-" + UUID().uuidString + "-" + suffix,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory.appendingPathComponent("vault.ccsql"), Data(repeating: 0x51, count: 32))
    }

    private func downgradeToV3(database: URL, key: Data) throws {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            database.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw NSError(domain: "SQLCipherReviewStateTests", code: Int(openResult))
        }
        defer { sqlite3_close(handle) }

        let keyResult = key.withUnsafeBytes { bytes in
            sqlite3_key(handle, bytes.baseAddress, Int32(bytes.count))
        }
        guard keyResult == SQLITE_OK else {
            throw NSError(domain: "SQLCipherReviewStateTests", code: Int(keyResult))
        }

        let statements = [
            "DROP TRIGGER spaces_after_document_insert;",
            "DROP TRIGGER spaces_after_receipt_insert;",
            "DROP INDEX space_project_lookup;",
            "DROP TABLE space_project_keys;",
            "DROP TABLE spaces;",
            "DROP TABLE reasoning_derivations;",
            "DROP TABLE reasoning_derived_cache;",
            "DROP TABLE reasoning_fact_evidence;",
            "DROP TABLE reasoning_base_facts;",
            "DROP TABLE reasoning_generations;",
            "DROP INDEX receipts_review;",
            "DROP INDEX documents_review;",
            "ALTER TABLE receipts DROP COLUMN review_state;",
            "ALTER TABLE documents DROP COLUMN review_state;",
            "PRAGMA user_version = 3;",
        ]
        for statement in statements {
            let result = sqlite3_exec(handle, statement, nil, nil, nil)
            guard result == SQLITE_OK else {
                throw NSError(domain: "SQLCipherReviewStateTests", code: Int(result))
            }
        }
    }
}
