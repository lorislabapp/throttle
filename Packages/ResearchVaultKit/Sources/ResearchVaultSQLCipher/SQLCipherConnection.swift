import Foundation
import SQLCipher

public enum SQLCipherValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

public enum SQLCipherBind: Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

public struct SQLCipherStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: Int32
    public let operation: String

    public init(code: Int32, operation: String) {
        self.code = code
        self.operation = operation
    }

    public var description: String {
        "SQLCipher operation failed (" + operation + ", code " + String(code) + ")"
    }
}

/// Minimal secret-safe wrapper over the official SQLCipher C module.
///
/// Errors expose an operation and numeric code only. Database messages can echo
/// SQL or values and therefore never cross this boundary into application logs.
final class SQLCipherConnection {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var handle: OpaquePointer?

    init(path: String, key: Data, readOnly: Bool = false, useWAL: Bool = true) throws {
        var database: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw SQLCipherStoreError(code: result, operation: "open")
        }
        handle = database

        do {
            let keyResult = key.withUnsafeBytes { bytes in
                sqlite3_key(database, bytes.baseAddress, Int32(bytes.count))
            }
            guard keyResult == SQLITE_OK else {
                throw SQLCipherStoreError(code: keyResult, operation: "key")
            }
            guard let version = try scalarText("PRAGMA cipher_version;"), !version.isEmpty else {
                throw SQLCipherStoreError(code: -1, operation: "cipher-version")
            }
            guard try scalarInteger("PRAGMA cipher_status;") == 1 else {
                throw SQLCipherStoreError(code: -1, operation: "cipher-status")
            }
            try execute("PRAGMA cipher_memory_security = ON;")
            // `cipher_version` proves that the codec is linked, but does not read
            // an encrypted page and therefore cannot validate the supplied key.
            // Force a schema-page read before exposing the connection.
            _ = try scalarInteger("SELECT count(*) FROM sqlite_master;")
            try execute("PRAGMA foreign_keys = ON;")
            try execute("PRAGMA trusted_schema = OFF;")
            try execute("PRAGMA secure_delete = ON;")
            try execute("PRAGMA temp_store = MEMORY;")
            if !readOnly {
                _ = try scalarText(useWAL ? "PRAGMA journal_mode = WAL;" : "PRAGMA journal_mode = DELETE;")
                try execute("PRAGMA synchronous = FULL;")
            }
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    func close() {
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    func execute(_ sql: String, binds: [SQLCipherBind] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(binds, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLCipherStoreError(code: result, operation: "execute")
        }
    }

    func rows(_ sql: String, binds: [SQLCipherBind] = []) throws -> [[SQLCipherValue]] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(binds, to: statement)
        var output: [[SQLCipherValue]] = []

        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return output }
            guard result == SQLITE_ROW else {
                throw SQLCipherStoreError(code: result, operation: "query")
            }
            var row: [SQLCipherValue] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER:
                    row.append(.integer(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT:
                    row.append(.real(sqlite3_column_double(statement, column)))
                case SQLITE_TEXT:
                    guard let value = sqlite3_column_text(statement, column) else {
                        row.append(.null)
                        continue
                    }
                    row.append(.text(String(cString: value)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    guard count > 0, let bytes = sqlite3_column_blob(statement, column) else {
                        row.append(.blob(Data()))
                        continue
                    }
                    row.append(.blob(Data(bytes: bytes, count: count)))
                default:
                    row.append(.null)
                }
            }
            output.append(row)
        }
    }

    func scalarText(_ sql: String, binds: [SQLCipherBind] = []) throws -> String? {
        guard let value = try rows(sql, binds: binds).first?.first else { return nil }
        if case let .text(text) = value { return text }
        return nil
    }

    func scalarInteger(_ sql: String, binds: [SQLCipherBind] = []) throws -> Int64? {
        guard let value = try rows(sql, binds: binds).first?.first else { return nil }
        if case let .integer(integer) = value { return integer }
        if case let .text(text) = value { return Int64(text) }
        return nil
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func backup(to path: String, key: Data) throws {
        guard let source = handle else {
            throw SQLCipherStoreError(code: SQLITE_MISUSE, operation: "backup-source-closed")
        }
        let destination = try SQLCipherConnection(path: path, key: key, useWAL: false)
        guard let destinationHandle = destination.handle else {
            throw SQLCipherStoreError(code: SQLITE_MISUSE, operation: "backup-destination-closed")
        }
        guard let backup = sqlite3_backup_init(destinationHandle, "main", source, "main") else {
            throw SQLCipherStoreError(
                code: sqlite3_errcode(destinationHandle),
                operation: "backup-init"
            )
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE else {
            throw SQLCipherStoreError(code: stepResult, operation: "backup-step")
        }
        guard finishResult == SQLITE_OK else {
            throw SQLCipherStoreError(code: finishResult, operation: "backup-finish")
        }
        destination.close()
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else {
            throw SQLCipherStoreError(code: SQLITE_MISUSE, operation: "closed")
        }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v3(
            handle,
            sql,
            -1,
            UInt32(SQLITE_PREPARE_PERSISTENT),
            &statement,
            nil
        )
        guard result == SQLITE_OK, let statement else {
            throw SQLCipherStoreError(code: result, operation: "prepare")
        }
        return statement
    }

    private func bind(_ values: [SQLCipherBind], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case let .integer(integer):
                result = sqlite3_bind_int64(statement, index, integer)
            case let .real(real):
                result = sqlite3_bind_double(statement, index, real)
            case let .text(text):
                result = sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case let .blob(data):
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        statement,
                        index,
                        bytes.baseAddress,
                        Int32(bytes.count),
                        Self.transient
                    )
                }
            }
            guard result == SQLITE_OK else {
                throw SQLCipherStoreError(code: result, operation: "bind")
            }
        }
    }
}
