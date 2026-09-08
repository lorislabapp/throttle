import CryptoKit
import Foundation
import ResearchVaultIngestion
import ResearchVaultModel
import ResearchVaultReasoning
import ResearchVaultStore

extension SQLCipherReceiptStore {

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
        _ = try validateBackup(at: backup, key: backupKey, allowHistoricalSchema: true)
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
        defer { source.close() }
        try source.backup(to: staging.path, key: destinationKey)
        source.close()
        // The original encrypted backup stays read-only. Upgrade a staging copy
        // with no WAL sidecar before validating and atomically publishing it.
        let upgrade = try SQLCipherConnection(path: staging.path, key: destinationKey, useWAL: false)
        defer { upgrade.close() }
        try SQLCipherSchema.migrate(upgrade)
        upgrade.close()
        let evidence = try validateBackup(at: staging, key: destinationKey)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: staging.path
        )
        try FileManager.default.moveItem(at: staging, to: destination)
        return evidence
    }

    static func validateBackup(
        at url: URL, key: Data, allowHistoricalSchema: Bool = false
    ) throws -> SQLCipherBackupEvidence {
        let validation = try SQLCipherConnection(path: url.path, key: key, readOnly: true)
        defer { validation.close() }
        let schemaVersion = Int(try validation.scalarInteger("PRAGMA user_version;") ?? -1)
        let cipherVersion = try validation.scalarText("PRAGMA cipher_version;") ?? ""
        let receiptCount = Int(try validation.scalarInteger("SELECT count(*) FROM receipts;") ?? -1)
        let documentCount = schemaVersion < 2 ? 0
            : Int(try validation.scalarInteger("SELECT count(*) FROM documents;") ?? -1)
        let chunkCount = schemaVersion < 2 ? 0
            : Int(try validation.scalarInteger("SELECT count(*) FROM document_chunks;") ?? -1)
        let quickCheck = try validation.scalarText("PRAGMA quick_check;") == "ok"
        let cipherIntegrity = try validation.rows("PRAGMA cipher_integrity_check;").isEmpty
        let foreignKeys = try validation.rows("PRAGMA foreign_key_check;").isEmpty
        guard
            schemaVersion == currentSchemaVersion
                || (allowHistoricalSchema && (1..<currentSchemaVersion).contains(schemaVersion)),
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

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func removeStagingFiles(_ database: URL) {
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
