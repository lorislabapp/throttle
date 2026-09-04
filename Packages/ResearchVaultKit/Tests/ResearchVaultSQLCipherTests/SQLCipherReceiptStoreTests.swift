import Foundation
import XCTest
import CryptoKit
import ResearchVaultIngestion
import ResearchVaultModel
import ResearchVaultStore
import ResearchVaultSQLCipher

final class SQLCipherReceiptStoreTests: XCTestCase {
    func testPersistentImportSearchIntegrityAndReopen() async throws {
        let (database, key) = try databaseFixture("roundtrip")
        let receipt = try makeReceipt(
            receiptID: "f1cc17e2-2148-443d-a715-ac84684896a8",
            projectKey: "throttle",
            sensitivity: .internal,
            claim: "BM25 is the measured retrieval baseline"
        )
        let grant = VaultAuthorization(
            projectKeys: ["throttle"],
            maximumSensitivity: .internal
        )

        let store = try SQLCipherReceiptStore(databaseURL: database, key: key)
        let firstImport = try await store.importReceipt(receipt, authorization: grant, reviewState: .approved)
        let secondImport = try await store.importReceipt(receipt, authorization: grant, reviewState: .approved)
        XCTAssertEqual(firstImport, .inserted)
        XCTAssertEqual(secondImport, .alreadyPresent)
        let hits = try await store.searchClaims(
            query: "measured retrieval",
            authorization: grant
        )
        XCTAssertEqual(hits.map(\.receiptID), [receipt.receiptID])
        XCTAssertEqual(hits.first?.status, .supported)

        let integrity = try await store.verifyIntegrity()
        XCTAssertEqual(integrity.schemaVersion, SQLCipherReceiptStore.currentSchemaVersion)
        XCTAssertEqual(integrity.receiptCount, 1)
        XCTAssertEqual(integrity.documentCount, 0)
        XCTAssertEqual(integrity.chunkCount, 0)
        XCTAssertTrue(integrity.quickCheckPassed)
        XCTAssertTrue(integrity.cipherIntegrityPassed)
        XCTAssertTrue(integrity.foreignKeysPassed)
        await store.close()

        let reopened = try SQLCipherReceiptStore(databaseURL: database, key: key)
        let reopenedReceipt = try await reopened.receipt(id: receipt.receiptID, authorization: grant)
        let reopenedReceipts = try await reopened.receipts(authorization: grant)
        XCTAssertEqual(reopenedReceipt, receipt)
        XCTAssertEqual(reopenedReceipts, [receipt])
    }

    func testProjectAndSensitivityFiltersApplyBeforeFTSResults() async throws {
        let (database, key) = try databaseFixture("scope")
        let store = try SQLCipherReceiptStore(databaseURL: database, key: key)
        let throttle = try makeReceipt(
            receiptID: "2b855157-7c70-4de4-b14e-6c8bd03296c8",
            projectKey: "throttle",
            sensitivity: .internal,
            claim: "shared sentinel evidence"
        )
        let cheatCode = try makeReceipt(
            receiptID: "e2631ef9-a14e-4b24-98a8-63f40ff3bb11",
            projectKey: "cheatcode",
            sensitivity: .public,
            claim: "shared sentinel evidence"
        )
        let admin = VaultAuthorization(
            projectKeys: ["throttle", "cheatcode"],
            maximumSensitivity: .restricted
        )
        _ = try await store.importReceipt(throttle, authorization: admin, reviewState: .approved)
        _ = try await store.importReceipt(cheatCode, authorization: admin, reviewState: .approved)

        let throttleOnly = VaultAuthorization(
            projectKeys: ["throttle"],
            maximumSensitivity: .restricted
        )
        let publicAll = VaultAuthorization(
            projectKeys: ["throttle", "cheatcode"],
            maximumSensitivity: .public
        )
        let throttleHits = try await store.searchClaims(
            query: "shared sentinel",
            authorization: throttleOnly
        )
        let publicHits = try await store.searchClaims(
            query: "shared sentinel",
            authorization: publicAll
        )

        XCTAssertEqual(throttleHits.map(\.projectKey), ["throttle"])
        XCTAssertEqual(publicHits.map(\.projectKey), ["cheatcode"])

        do {
            _ = try await store.receipt(id: cheatCode.receiptID, authorization: throttleOnly)
            XCTFail("Cross-project receipt read must fail")
        } catch {
            XCTAssertEqual(error as? ReceiptStoreError, .authorizationDenied)
        }
    }

    func testFTSInputCannotInjectOperatorsOrEscapePolicy() async throws {
        let (database, key) = try databaseFixture("fts-input")
        let store = try SQLCipherReceiptStore(databaseURL: database, key: key)
        let receipt = try makeReceipt(
            receiptID: "5c7e8735-a11e-42bd-9ee6-d94b01a42368",
            projectKey: "throttle",
            sensitivity: .internal,
            claim: "safe searchable claim"
        )
        let grant = VaultAuthorization(
            projectKeys: ["throttle"],
            maximumSensitivity: .internal
        )
        _ = try await store.importReceipt(receipt, authorization: grant, reviewState: .approved)

        let hostile = try await store.searchClaims(
            query: #"safe" OR * NOT "#,
            authorization: grant
        )
        XCTAssertEqual(Set(hostile.map(\.receiptID)), [receipt.receiptID])

        do {
            _ = try await store.searchClaims(query: "\" ; --", authorization: grant)
            XCTFail("Punctuation-only query must fail")
        } catch {
            XCTAssertEqual(error as? ClaimSearchError, .emptyQuery)
        }
    }

    func testFunctionWordsDoNotDecideWhichClaimMatches() async throws {
        // unicode61 has no stoplist and every token is OR'd, so a written
        // question used to let a claim win purely on shared function words.
        // Measured on the sibling DeepSearsh index built the same way, a GPU
        // question returned a report on protecting a lone parent. Content words
        // must decide the match; function words must not be able to.
        let (database, key) = try databaseFixture("fts-stopwords")
        let store = try SQLCipherReceiptStore(databaseURL: database, key: key)
        let grant = VaultAuthorization(projectKeys: ["throttle"], maximumSensitivity: .internal)

        let onTopic = try makeReceipt(
            receiptID: "1f2b4a1e-3c5d-4e6f-8a9b-0c1d2e3f4a5b",
            projectKey: "throttle",
            sensitivity: .internal,
            claim: "coral accelerator runs alongside the discrete gpu"
        )
        // Shares only function words with the question, and is longer, which is
        // exactly the shape that used to win.
        let offTopic = try makeReceipt(
            receiptID: "2a3b4c5d-6e7f-4890-a1b2-c3d4e5f60718",
            projectKey: "throttle",
            sensitivity: .internal,
            claim: "on peut aussi le faire pour tout le reste et on peut le refaire ensuite"
        )
        _ = try await store.importReceipt(onTopic, authorization: grant, reviewState: .approved)
        _ = try await store.importReceipt(offTopic, authorization: grant, reviewState: .approved)

        let hits = try await store.searchClaims(
            query: "et du coup on peut aussi utiliser le coral avec le gpu ou pas",
            authorization: grant
        )
        XCTAssertEqual(hits.first?.receiptID, onTopic.receiptID,
                       "content words must outrank a claim sharing only function words")

        // A question made only of function words must still return something
        // rather than silently matching nothing.
        let allFunctionWords = try await store.searchClaims(
            query: "et on peut le faire aussi", authorization: grant)
        XCTAssertFalse(allFunctionWords.isEmpty,
                       "a query of only function words must not degrade to an empty match")
    }

    func testReceiptIDConflictRollsBackWithoutChangingAcceptedReceipt() async throws {
        let (database, key) = try databaseFixture("conflict")
        let store = try SQLCipherReceiptStore(databaseURL: database, key: key)
        let id = "f6a8f84a-168e-43f1-9224-34e9df991381"
        let first = try makeReceipt(
            receiptID: id,
            projectKey: "throttle",
            sensitivity: .internal,
            claim: "first accepted claim"
        )
        let conflicting = try makeReceipt(
            receiptID: id,
            projectKey: "throttle",
            sensitivity: .internal,
            claim: "conflicting claim"
        )
        let grant = VaultAuthorization(
            projectKeys: ["throttle"],
            maximumSensitivity: .internal
        )
        _ = try await store.importReceipt(first, authorization: grant, reviewState: .approved)

        do {
            _ = try await store.importReceipt(conflicting, authorization: grant, reviewState: .approved)
            XCTFail("Conflicting content must fail")
        } catch {
            XCTAssertEqual(error as? ReceiptStoreError, .receiptIDConflict(id))
        }
        let storedReceipt = try await store.receipt(id: id, authorization: grant)
        let integrity = try await store.verifyIntegrity()
        XCTAssertEqual(storedReceipt, first)
        XCTAssertEqual(integrity.receiptCount, 1)
    }

    func testOwnerBatchPreflightPreventsPartialUnauthorizedImport() async throws {
        let (database, key) = try databaseFixture("owner-batch-atomic")
        let store = try SQLCipherReceiptStore(databaseURL: database, key: key)
        let allowed = try makeReceipt(
            receiptID: "05855b40-a6a8-4559-9aad-c2086f662579",
            projectKey: "throttle",
            sensitivity: .internal,
            claim: "allowed but must roll back with the batch"
        )
        let denied = try makeReceipt(
            receiptID: "621f0f0c-9157-4ba9-947d-90388f46d866",
            projectKey: "other-project",
            sensitivity: .internal,
            claim: "outside the immutable owner grant"
        )
        let grant = VaultAuthorization(
            projectKeys: ["throttle"],
            maximumSensitivity: .internal
        )

        do {
            _ = try await store.importReceipts(
                [allowed, denied],
                authorization: grant,
                reviewState: .approved
            )
            XCTFail("the whole owner batch must fail")
        } catch {
            XCTAssertEqual(error as? ReceiptStoreError, .authorizationDenied)
        }
        let evidence = try await store.verifyIntegrity()
        XCTAssertEqual(evidence.receiptCount, 0)
    }

    func testDocumentImportSearchIdempotenceAndPolicyIsolation() async throws {
        let (database, key) = try databaseFixture("documents")
        let store = try SQLCipherReceiptStore(databaseURL: database, key: key)
        let admin = VaultAuthorization(
            projectKeys: ["throttle", "cheatcode"],
            maximumSensitivity: .restricted
        )
        let throttle = makeDocument(
            id: "dr-throttle", project: "throttle", sensitivity: .internal,
            text: "# Retrieval\n\nReciprocal rank fusion benchmark sentinel."
        )
        let cheatCode = makeDocument(
            id: "dr-cheatcode", project: "cheatcode", sensitivity: .confidential,
            text: "# Retrieval\n\nReciprocal rank fusion benchmark sentinel."
        )
        let first = try await store.importDocument(throttle, authorization: admin, reviewState: .approved)
        let second = try await store.importDocument(throttle, authorization: admin, reviewState: .approved)
        _ = try await store.importDocument(cheatCode, authorization: admin, reviewState: .approved)
        guard case let .inserted(chunkCount) = first else { return XCTFail("expected insert") }
        XCTAssertGreaterThan(chunkCount, 0)
        XCTAssertEqual(second, .alreadyPresent)

        let throttleOnly = VaultAuthorization(
            projectKeys: ["throttle"], maximumSensitivity: .internal
        )
        let hits = try await store.searchDocuments(
            query: #"fusion" OR * NOT "#,
            authorization: throttleOnly
        )
        XCTAssertEqual(hits.map(\.documentID), ["dr-throttle"])
        XCTAssertTrue(hits[0].content.contains("benchmark sentinel"))
        XCTAssertEqual(hits[0].plaintextSHA256, throttle.plaintextSHA256)

        let publicGrant = VaultAuthorization(
            projectKeys: ["throttle", "cheatcode"], maximumSensitivity: .public
        )
        let publicHits = try await store.searchDocuments(
            query: "benchmark", authorization: publicGrant
        )
        XCTAssertTrue(publicHits.isEmpty)
    }

    func testDocumentIDConflictAndUnauthorizedImportFailClosed() async throws {
        let (database, key) = try databaseFixture("document-conflict")
        let store = try SQLCipherReceiptStore(databaseURL: database, key: key)
        let grant = VaultAuthorization(projectKeys: ["throttle"], maximumSensitivity: .internal)
        let first = makeDocument(id: "dr-same", project: "throttle", sensitivity: .internal, text: "first")
        let conflict = makeDocument(id: "dr-same", project: "throttle", sensitivity: .internal, text: "second")
        _ = try await store.importDocument(first, authorization: grant, reviewState: .approved)
        do {
            _ = try await store.importDocument(conflict, authorization: grant, reviewState: .approved)
            XCTFail("conflict must fail")
        } catch {
            XCTAssertEqual(error as? SQLCipherVaultError, .documentIDConflict("dr-same"))
        }
        do {
            _ = try await store.importDocument(
                makeDocument(id: "dr-other", project: "cheatcode", sensitivity: .internal, text: "x"),
                authorization: grant,
                reviewState: .approved
            )
            XCTFail("cross-project import must fail")
        } catch {
            XCTAssertEqual(error as? ReceiptStoreError, .authorizationDenied)
        }
    }

    func testBackupIsEncryptedVerifiedAndRestoresUnderNewKey() async throws {
        let (database, databaseKey) = try databaseFixture("backup-source")
        let sourceStore = try SQLCipherReceiptStore(databaseURL: database, key: databaseKey)
        let receipt = try makeReceipt(
            receiptID: "24a4186e-7d79-46ad-9bb4-e8b99c4be0f0",
            projectKey: "throttle",
            sensitivity: .confidential,
            claim: "encrypted backup sentinel"
        )
        let grant = VaultAuthorization(
            projectKeys: ["throttle"],
            maximumSensitivity: .confidential
        )
        _ = try await sourceStore.importReceipt(receipt, authorization: grant, reviewState: .approved)
        let document = makeDocument(
            id: "dr-backup", project: "throttle", sensitivity: .confidential,
            text: "# Backup\n\nRestored document retrieval sentinel."
        )
        let documentResult = try await sourceStore.importDocument(
            document,
            authorization: grant,
            reviewState: .approved
        )
        guard case let .inserted(expectedChunks) = documentResult else {
            return XCTFail("expected document insert")
        }

        let backupKey = Data(repeating: 0x6b, count: 32)
        let backup = database.deletingLastPathComponent().appendingPathComponent("vault.backup")
        let backupEvidence = try await sourceStore.createBackup(at: backup, backupKey: backupKey)
        XCTAssertEqual(backupEvidence.receiptCount, 1)
        XCTAssertEqual(backupEvidence.documentCount, 1)
        XCTAssertEqual(backupEvidence.chunkCount, expectedChunks)
        XCTAssertEqual(backupEvidence.ciphertextSHA256.count, 64)
        XCTAssertTrue(try SQLCipherRuntime.verify(databaseURL: backup, key: backupKey).plaintextHeaderAbsent)
        XCTAssertThrowsError(
            try SQLCipherRuntime.verify(
                databaseURL: backup,
                key: Data(repeating: 0x6c, count: 32)
            )
        )

        let restored = database.deletingLastPathComponent().appendingPathComponent("restored.ccsql")
        let restoredKey = Data(repeating: 0x7d, count: 32)
        let restoreEvidence = try SQLCipherReceiptStore.restoreBackup(
            from: backup,
            backupKey: backupKey,
            to: restored,
            destinationKey: restoredKey
        )
        XCTAssertEqual(restoreEvidence.receiptCount, 1)
        XCTAssertEqual(restoreEvidence.documentCount, 1)
        XCTAssertEqual(restoreEvidence.chunkCount, expectedChunks)
        XCTAssertNotEqual(backupEvidence.ciphertextSHA256, restoreEvidence.ciphertextSHA256)

        let restoredStore = try SQLCipherReceiptStore(databaseURL: restored, key: restoredKey)
        let restoredReceipt = try await restoredStore.receipt(id: receipt.receiptID, authorization: grant)
        let restoredIntegrity = try await restoredStore.verifyIntegrity()
        let restoredHits = try await restoredStore.searchDocuments(
            query: "retrieval sentinel", authorization: grant
        )
        XCTAssertEqual(restoredReceipt, receipt)
        XCTAssertEqual(restoredIntegrity.receiptCount, 1)
        XCTAssertEqual(restoredIntegrity.documentCount, 1)
        XCTAssertEqual(restoredIntegrity.chunkCount, expectedChunks)
        XCTAssertEqual(restoredHits.map(\.documentID), ["dr-backup"])
    }

    func testBackupNeverOverwritesExistingDestination() async throws {
        let (database, databaseKey) = try databaseFixture("backup-existing")
        let store = try SQLCipherReceiptStore(databaseURL: database, key: databaseKey)
        let backup = database.deletingLastPathComponent().appendingPathComponent("existing.backup")
        let sentinel = Data("do-not-overwrite".utf8)
        try sentinel.write(to: backup)

        do {
            _ = try await store.createBackup(
                at: backup,
                backupKey: Data(repeating: 0x22, count: 32)
            )
            XCTFail("Existing backup destination must not be overwritten")
        } catch {
            XCTAssertEqual(error as? SQLCipherBackupError, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: backup), sentinel)
    }

    func testTamperedBackupCannotBeRestoredAndLeavesNoFinalDatabase() async throws {
        let (database, databaseKey) = try databaseFixture("backup-tamper")
        let store = try SQLCipherReceiptStore(databaseURL: database, key: databaseKey)
        let backupKey = Data(repeating: 0x23, count: 32)
        let backup = database.deletingLastPathComponent().appendingPathComponent("tampered.backup")
        _ = try await store.createBackup(at: backup, backupKey: backupKey)

        var data = try Data(contentsOf: backup)
        let index = data.index(data.startIndex, offsetBy: min(5_000, data.count - 1))
        data[index] ^= 0xff
        try data.write(to: backup, options: .atomic)

        let restored = database.deletingLastPathComponent().appendingPathComponent("must-not-exist.ccsql")
        XCTAssertThrowsError(
            try SQLCipherReceiptStore.restoreBackup(
                from: backup,
                backupKey: backupKey,
                to: restored,
                destinationKey: Data(repeating: 0x24, count: 32)
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.path))
    }

    private func makeReceipt(
        receiptID: String,
        projectKey: String,
        sensitivity: ResearchSensitivity,
        claim: String
    ) throws -> ResearchReceipt {
        let sourceID = "source-" + receiptID
        return try ResearchReceipt.seal(
            receiptID: receiptID,
            sessionID: "session-" + receiptID,
            agentID: "agent-1",
            projectKey: projectKey,
            question: "What evidence is available?",
            findings: [
                ResearchFinding(
                    claim: claim,
                    status: .supported,
                    evidenceIDs: [sourceID]
                ),
            ],
            sources: [
                ResearchSource(
                    id: sourceID,
                    kind: .file,
                    locator: "evidence/" + receiptID + ".md",
                    observedAt: Date(timeIntervalSince1970: 1_787_832_000),
                    sha256: String(repeating: "d", count: 64)
                ),
            ],
            sensitivity: sensitivity,
            createdAt: Date(timeIntervalSince1970: 1_787_832_000)
        )
    }

    private func makeDocument(
        id: String,
        project: String,
        sensitivity: ResearchSensitivity,
        text: String
    ) -> ResearchDocumentCandidate {
        let data = Data(text.utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ResearchDocumentCandidate(
            documentID: id,
            title: "Document " + id,
            projectKey: project,
            category: "technical",
            libraryPath: "library/technical/" + project + "/" + id + ".md",
            origins: ["/private/origin.md"],
            content: text,
            plaintextSHA256: hash,
            byteCount: data.count,
            modifiedAt: Date(timeIntervalSince1970: 1_787_832_000),
            sensitivity: sensitivity
        )
    }

    private func databaseFixture(_ suffix: String) throws -> (URL, Data) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResearchVaultPersistent-" + UUID().uuidString + "-" + suffix)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (
            directory.appendingPathComponent("vault.ccsql"),
            Data(repeating: 0x5a, count: 32)
        )
    }
}
