import Darwin
import Foundation

public struct SQLCipherRuntimeEvidence: Equatable, Sendable {
    public let cipherVersion: String
    public let plaintextHeaderAbsent: Bool

    public init(cipherVersion: String, plaintextHeaderAbsent: Bool) {
        self.cipherVersion = cipherVersion
        self.plaintextHeaderAbsent = plaintextHeaderAbsent
    }
}

@_spi(Testing)
public struct SQLCipherCrashRecoveryEvidence: Equatable, Sendable {
    public let committedRowCount: Int
    public let schemaVersion: Int
    public let partialMigrationAbsent: Bool
    public let quickCheckPassed: Bool
    public let cipherIntegrityPassed: Bool

    public init(
        committedRowCount: Int,
        schemaVersion: Int,
        partialMigrationAbsent: Bool,
        quickCheckPassed: Bool,
        cipherIntegrityPassed: Bool
    ) {
        self.committedRowCount = committedRowCount
        self.schemaVersion = schemaVersion
        self.partialMigrationAbsent = partialMigrationAbsent
        self.quickCheckPassed = quickCheckPassed
        self.cipherIntegrityPassed = cipherIntegrityPassed
    }
}

public enum SQLCipherRuntime {
    /// Creates a keyed database, forces a page write, and proves both that the
    /// SQLCipher codec is active and that the SQLite plaintext header is absent.
    public static func probe(databaseURL: URL, key: Data) throws -> SQLCipherRuntimeEvidence {
        guard key.count == 32 else {
            throw SQLCipherStoreError(code: -1, operation: "invalid-key-length")
        }
        let connection = try SQLCipherConnection(path: databaseURL.path, key: key)
        let version = try connection.scalarText("PRAGMA cipher_version;") ?? ""
        try connection.execute(
            "CREATE TABLE IF NOT EXISTS runtime_probe(id INTEGER PRIMARY KEY, value TEXT NOT NULL);"
        )
        try connection.execute(
            "INSERT OR REPLACE INTO runtime_probe(id, value) VALUES (?1, ?2);",
            binds: [.integer(1), .text("encrypted")]
        )
        connection.close()

        let prefix = try Data(contentsOf: databaseURL).prefix(16)
        let plaintextHeader = Data("SQLite format 3\0".utf8)
        return SQLCipherRuntimeEvidence(
            cipherVersion: version,
            plaintextHeaderAbsent: prefix != plaintextHeader
        )
    }

    /// Reopens an existing database and forces a schema read. A wrong key,
    /// plaintext database, corrupt header or unavailable codec throws.
    public static func verify(databaseURL: URL, key: Data) throws -> SQLCipherRuntimeEvidence {
        guard key.count == 32 else {
            throw SQLCipherStoreError(code: -1, operation: "invalid-key-length")
        }
        let connection = try SQLCipherConnection(path: databaseURL.path, key: key, readOnly: true)
        let version = try connection.scalarText("PRAGMA cipher_version;") ?? ""
        _ = try connection.scalarInteger("SELECT count(*) FROM sqlite_master;")
        connection.close()

        let prefix = try Data(contentsOf: databaseURL).prefix(16)
        let plaintextHeader = Data("SQLite format 3\0".utf8)
        return SQLCipherRuntimeEvidence(
            cipherVersion: version,
            plaintextHeaderAbsent: prefix != plaintextHeader
        )
    }

    @_spi(Testing)
    public static func prepareWriteCrashProbe(databaseURL: URL, key: Data) throws {
        let connection = try SQLCipherConnection(path: databaseURL.path, key: key)
        try connection.execute(
            "CREATE TABLE crash_probe(id INTEGER PRIMARY KEY, payload BLOB NOT NULL);"
        )
        try connection.execute(
            "INSERT INTO crash_probe(id, payload) VALUES (?1, ?2);",
            binds: [.integer(1), .blob(Data("committed".utf8))]
        )
        connection.close()
    }

    @_spi(Testing)
    public static func terminateDuringWriteProbe(databaseURL: URL, key: Data) throws -> Never {
        let connection = try SQLCipherConnection(path: databaseURL.path, key: key)
        try connection.execute("PRAGMA cache_size = 8;")
        try connection.execute("BEGIN IMMEDIATE;")
        let payload = Data(repeating: 0xa5, count: 4_096)
        for identifier in 2...2_048 {
            try connection.execute(
                "INSERT INTO crash_probe(id, payload) VALUES (?1, ?2);",
                binds: [.integer(Int64(identifier)), .blob(payload)]
            )
        }
        _exit(86)
    }

    @_spi(Testing)
    public static func verifyWriteCrashProbe(
        databaseURL: URL,
        key: Data
    ) throws -> SQLCipherCrashRecoveryEvidence {
        let connection = try SQLCipherConnection(path: databaseURL.path, key: key)
        defer { connection.close() }
        let count = Int(try connection.scalarInteger("SELECT count(*) FROM crash_probe;") ?? -1)
        let evidence = try crashEvidence(connection, committedRowCount: count)
        guard count == 1, evidence.quickCheckPassed, evidence.cipherIntegrityPassed else {
            throw SQLCipherStoreError(code: -1, operation: "write-crash-recovery")
        }
        return evidence
    }

    @_spi(Testing)
    public static func prepareMigrationCrashProbe(databaseURL: URL, key: Data) throws {
        let connection = try SQLCipherConnection(path: databaseURL.path, key: key)
        connection.close()
    }

    @_spi(Testing)
    public static func terminateDuringMigrationProbe(databaseURL: URL, key: Data) throws -> Never {
        let connection = try SQLCipherConnection(path: databaseURL.path, key: key)
        try connection.execute("PRAGMA cache_size = 8;")
        try connection.execute("BEGIN IMMEDIATE;")
        try connection.execute(
            "CREATE TABLE partial_migration(id INTEGER PRIMARY KEY, payload BLOB NOT NULL);"
        )
        try connection.execute("PRAGMA user_version = 99;")
        let payload = Data(repeating: 0x5a, count: 4_096)
        for identifier in 1...2_048 {
            try connection.execute(
                "INSERT INTO partial_migration(id, payload) VALUES (?1, ?2);",
                binds: [.integer(Int64(identifier)), .blob(payload)]
            )
        }
        _exit(86)
    }

    @_spi(Testing)
    public static func verifyMigrationCrashProbe(
        databaseURL: URL,
        key: Data
    ) throws -> SQLCipherCrashRecoveryEvidence {
        let connection = try SQLCipherConnection(path: databaseURL.path, key: key)
        defer { connection.close() }
        let evidence = try crashEvidence(connection, committedRowCount: 0)
        guard
            evidence.schemaVersion == 0,
            evidence.partialMigrationAbsent,
            evidence.quickCheckPassed,
            evidence.cipherIntegrityPassed
        else {
            throw SQLCipherStoreError(code: -1, operation: "migration-crash-recovery")
        }
        return evidence
    }

    private static func crashEvidence(
        _ connection: SQLCipherConnection,
        committedRowCount: Int
    ) throws -> SQLCipherCrashRecoveryEvidence {
        let schemaVersion = Int(try connection.scalarInteger("PRAGMA user_version;") ?? -1)
        let partialCount = Int(
            try connection.scalarInteger(
                "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'partial_migration';"
            ) ?? -1
        )
        return SQLCipherCrashRecoveryEvidence(
            committedRowCount: committedRowCount,
            schemaVersion: schemaVersion,
            partialMigrationAbsent: partialCount == 0,
            quickCheckPassed: try connection.scalarText("PRAGMA quick_check;") == "ok",
            cipherIntegrityPassed: try connection.rows("PRAGMA cipher_integrity_check;").isEmpty
        )
    }
}
