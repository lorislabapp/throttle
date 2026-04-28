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

        // v2: usage_snapshots table — persisted history for the Stats tab.
        // Bucketed: each row is keyed by (timestamp_bucket, window_kind) so a
        // burst of refresh() calls collapses into one row per 5-minute slot.
        migrator.registerMigration("v2_usage_snapshots") { db in
            try db.create(table: "usage_snapshots") { t in
                t.column("timestamp_bucket", .integer).notNull()
                t.column("window_kind", .text).notNull()
                t.column("used_tokens", .integer).notNull()
                t.column("cap_tokens", .integer)
                t.primaryKey(["timestamp_bucket", "window_kind"])
            }
            try db.create(
                index: "idx_snap_timestamp",
                on: "usage_snapshots",
                columns: ["timestamp_bucket"]
            )
        }

        // v3: tokopt_savings — per-hook-fire records of bytes saved.
        // Hooks (session-start-router.sh, pre-compact.sh) append JSONL to
        // ~/Library/Application Support/Throttle/savings.jsonl, which a
        // Throttle ingester sweeps into this table.
        migrator.registerMigration("v3_tokopt_savings") { db in
            try db.create(table: "tokopt_savings") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .integer).notNull()
                t.column("hook", .text).notNull()
                t.column("baseline_bytes", .integer).notNull()
                t.column("actual_bytes", .integer).notNull()
            }
            try db.create(
                index: "idx_savings_timestamp",
                on: "tokopt_savings",
                columns: ["timestamp"]
            )
        }

        try migrator.migrate(writer)
    }
}
