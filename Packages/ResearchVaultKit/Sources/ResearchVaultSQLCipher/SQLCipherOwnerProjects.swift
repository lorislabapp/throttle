import Foundation

extension SQLCipherReceiptStore {
    /// Stored independently of receipt/project metadata. Only the owner gateway
    /// uses this SPI; third-party grants do not read it.
    @_spi(OwnerProjectAdministration)
    public func ownerProjectKeys() throws -> Set<String> {
        let rows = try connection.rows("SELECT project_key FROM owner_project_grants ORDER BY project_key;")
        return Set(try rows.map { row in
            guard case .text(let key) = row[0] else {
                throw SQLCipherStoreError(code: -1, operation: "invalid-owner-project")
            }
            return key
        })
    }

    @_spi(OwnerProjectAdministration)
    public func admitOwnerProjects(_ keys: Set<String>) throws -> Set<String> {
        guard (1...64).contains(keys.count), keys.allSatisfy({ key in
            key.range(of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
        }) else { throw SQLCipherStoreError(code: -1, operation: "invalid-owner-projects") }
        return try connection.transaction {
            let admitted = try ownerProjectKeys().union(keys)
            guard admitted.count <= 4096 else {
                throw SQLCipherStoreError(code: -1, operation: "owner-project-limit")
            }
            for key in keys.sorted() {
                try connection.execute(
                    "INSERT OR IGNORE INTO owner_project_grants(project_key) VALUES (?1);",
                    binds: [.text(key)]
                )
            }
            return admitted
        }
    }
}
