import Foundation
import GRDB

enum Migrations {
    static func register(on writer: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "usage_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("session_id", .text).notNull()
                t.column("timestamp", .integer).notNull()
                t.column("model", .text).notNull()
                t.column("input_tokens", .integer).notNull().defaults(to: 0)
                t.column("output_tokens", .integer).notNull().defaults(to: 0)
                t.column("cache_create", .integer).notNull().defaults(to: 0)
                t.column("cache_read", .integer).notNull().defaults(to: 0)
                t.column("service_tier", .text)
            }
            try db.create(index: "idx_timestamp", on: "usage_events", columns: ["timestamp"])
            try db.create(index: "idx_session", on: "usage_events", columns: ["session_id"])

            try db.create(table: "calibration") { t in
                t.primaryKey("window_kind", .text)
                t.column("cap_tokens", .integer).notNull()
                t.column("source", .text).notNull()
                t.column("updated_at", .integer).notNull()
            }

            try db.create(table: "settings") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }

            try db.create(table: "file_state") { t in
                t.primaryKey("path", .text)
                t.column("last_offset", .integer).notNull()
                t.column("last_mtime", .integer).notNull()
            }
        }

        try migrator.migrate(writer)
    }
}
