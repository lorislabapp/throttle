import Foundation

/// Ordered schema steps, each committed atomically with its user_version.
/// SQL statements are kept separately from store/query behavior.
enum SQLCipherSchema {
    static func migrate(_ connection: SQLCipherConnection) throws {
        let current = Int(try connection.scalarInteger("PRAGMA user_version;") ?? 0)
        guard (0...SQLCipherReceiptStore.currentSchemaVersion).contains(current) else {
            throw SQLCipherVaultError.unsupportedSchemaVersion(current)
        }
        guard current < SQLCipherReceiptStore.currentSchemaVersion else { return }
        for version in (current + 1)...SQLCipherReceiptStore.currentSchemaVersion {
            try connection.transaction {
                for statement in statements(for: version) { try connection.execute(statement) }
                try connection.execute("PRAGMA user_version = \(version);")
            }
        }
    }

    private static func statements(for version: Int) -> [String] {
        switch version {
        case 1: version1
        case 2: version2
        case 3: version3
        case 4: version4
        case 5: version5
        case 6: version6
        case 7: version7
        default: []
        }
    }
}
