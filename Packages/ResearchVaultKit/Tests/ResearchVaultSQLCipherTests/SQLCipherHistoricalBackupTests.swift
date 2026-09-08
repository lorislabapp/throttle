import Foundation
import ResearchVaultModel
@testable import ResearchVaultSQLCipher
import Testing

@Suite("Historical encrypted backup restoration")
struct SQLCipherHistoricalBackupTests {
    @Test("v6 backup is preserved and its copy migrates with review state intact")
    func migrateCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-v6-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 0x54, count: 32)
        let database = root.appendingPathComponent("source.ccsql")
        let backup = root.appendingPathComponent("historical.backup")
        let restored = root.appendingPathComponent("restored.ccsql")
        let grant = VaultAuthorization(projectKeys: ["throttle"], maximumSensitivity: .restricted)
        let store = try SQLCipherReceiptStore(databaseURL: database, key: key)
        let approved = try receipt("approved")
        let quarantined = try receipt("quarantined")
        _ = try await store.importReceipt(approved, authorization: grant, reviewState: .approved)
        _ = try await store.importReceipt(quarantined, authorization: grant, reviewState: .quarantined)
        _ = try await store.createBackup(at: backup, backupKey: key)
        await store.close()

        // Derive the exact prior schema from the current fixture, preserving its
        // encrypted receipt payloads and all v6 tables/triggers.
        let historical = try SQLCipherConnection(path: backup.path, key: key, useWAL: false)
        try historical.execute("DROP TABLE owner_project_grants;")
        try historical.execute("DROP INDEX findings_receipt_order;")
        try historical.execute("PRAGMA user_version = 6;")
        historical.close()
        let originalBytes = try Data(contentsOf: backup)
        let evidence = try SQLCipherReceiptStore.restoreBackup(
            from: backup, backupKey: key, to: restored, destinationKey: key
        )
        #expect(evidence.schemaVersion == 7)
        #expect(try Data(contentsOf: backup) == originalBytes)
        let restoredStore = try SQLCipherReceiptStore(databaseURL: restored, key: key)
        #expect(try await restoredStore.receipts(authorization: grant) == [approved])
        #expect(
            try await restoredStore.quarantinedReceipts(authorization: grant).map(\.receiptID) == [
                quarantined.receiptID
            ])
        #expect(try await restoredStore.verifyIntegrity().foreignKeysPassed)
        await restoredStore.close()
    }

    private func receipt(_ name: String) throws -> ResearchReceipt {
        // The receipt wire contract stores milliseconds, so compare a fixture
        // representable at that precision rather than a wall-clock nanosecond.
        let observedAt = Date(timeIntervalSince1970: 1_787_832_000)
        return try ResearchReceipt.seal(
            receiptID: UUID().uuidString.lowercased(), sessionID: "backup-test", agentID: "test",
            projectKey: "throttle", question: "Preserve " + name,
            findings: [.init(claim: name, status: .open, evidenceIDs: ["source"])],
            sources: [.init(id: "source", kind: .file, locator: "fixture.md", observedAt: observedAt,
                            sha256: String(repeating: "b", count: 64))],
            sensitivity: .internal, createdAt: observedAt
        )
    }
}
