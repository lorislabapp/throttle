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

        // v4: indexed encoded_project column on file_state.
        // Per-project queries used to JOIN via `LIKE '%/<encoded>/%.jsonl'`,
        // which SQLite cannot index — full table scan over ~6700 rows for
        // each query, multiplied by 5 queries per project click → a 10-20s
        // freeze when opening the project window's Stats tab. With this
        // column populated and indexed, the same query becomes a B-tree
        // lookup.
        migrator.registerMigration("v4_file_state_encoded_project") { db in
            try db.alter(table: "file_state") { t in
                t.add(column: "encoded_project", .text)
            }
            try db.execute(sql: """
                UPDATE file_state
                SET encoded_project = CASE
                    WHEN path LIKE '%/projects/%' THEN
                        substr(
                            substr(path, instr(path, '/projects/') + 10),
                            1,
                            instr(substr(path, instr(path, '/projects/') + 10), '/') - 1
                        )
                    ELSE NULL
                END
            """)
            try db.create(
                index: "idx_fs_encoded_project",
                on: "file_state",
                columns: ["encoded_project"]
            )
        }

        // v5: indexed session_id column on file_state. The per-project
        // JOIN was still slow under v4 because it used a LIKE pattern,
        // which SQLite can't index. With session_id stored as a column
        // and indexed, the JOIN becomes an equality lookup → instant.
        migrator.registerMigration("v5_file_state_session_id") { db in
            try db.alter(table: "file_state") { t in
                t.add(column: "session_id", .text)
            }
            // Backfill via Swift — SQLite lacks `reverse()`/`rinstr()` so
            // extracting the basename in pure SQL would be ugly. The
            // session_id is the path's last component minus `.jsonl`.
            let rows = try Row.fetchAll(db, sql: "SELECT path FROM file_state")
            for row in rows {
                guard let path: String = row["path"] else { continue }
                let last = (path as NSString).lastPathComponent
                guard last.hasSuffix(".jsonl") else { continue }
                let sid = String(last.dropLast(".jsonl".count))
                try db.execute(
                    sql: "UPDATE file_state SET session_id = ? WHERE path = ?",
                    arguments: [sid, path]
                )
            }
            try db.create(
                index: "idx_fs_session_id",
                on: "file_state",
                columns: ["session_id"]
            )
        }

        // v6: dedupe usage_events + UNIQUE natural key → idempotent ingestion.
        // Re-scans (file rotation / watcher races) were re-inserting identical
        // events: ~12% of rows were exact full-row duplicates, inflating every
        // token/cost metric. Keep the earliest row per natural key, then enforce
        // uniqueness so future re-inserts are no-ops (paired with the
        // INSERT OR IGNORE conflict policy on UsageEvent).
        migrator.registerMigration("v6_dedupe_usage_events") { db in
            // Build a NON-unique covering index on the natural key FIRST so the
            // dedupe GROUP BY is index-backed — otherwise the anti-join DELETE is
            // an unindexed O(n) self-join that can hang launch for tens of seconds
            // on a large usage.db (H03). The UNIQUE index can only be created
            // AFTER duplicates are gone.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_usage_natural_tmp
                ON usage_events(session_id, timestamp, model,
                                input_tokens, output_tokens, cache_create, cache_read)
                """)
            try db.execute(sql: """
                DELETE FROM usage_events
                WHERE id NOT IN (
                    SELECT MIN(id) FROM usage_events
                    GROUP BY session_id, timestamp, model,
                             input_tokens, output_tokens, cache_create, cache_read
                )
                """)
            try db.execute(sql: "DROP INDEX IF EXISTS idx_usage_natural_tmp")
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_usage_natural
                ON usage_events(session_id, timestamp, model,
                                input_tokens, output_tokens, cache_create, cache_read)
                """)
        }

        // v7: traycer_events — Claude Code OTel log records (skill_activated,
        // tool_result, tool_decision) captured by the local OTLP receiver, keyed
        // by session_id so cost/token data in usage_events joins by equality.
        // UNIQUE(session_id, sequence) makes replayed OTLP batches (the exporter
        // retries on transient failure) idempotent via INSERT OR IGNORE.
        migrator.registerMigration("v7_traycer_events") { db in
            try db.create(table: "traycer_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("session_id", .text).notNull()
                t.column("sequence", .integer).notNull().defaults(to: 0)
                t.column("ts", .integer).notNull()
                t.column("event_type", .text).notNull()
                t.column("tool_name", .text)
                t.column("skill_name", .text)
                t.column("full_command", .text)
                t.column("decision", .text)
                t.column("success", .boolean)
            }
            try db.create(index: "idx_traycer_session", on: "traycer_events", columns: ["session_id"])
            try db.create(index: "idx_traycer_ts", on: "traycer_events", columns: ["ts"])
            try db.create(index: "idx_traycer_natural", on: "traycer_events",
                          columns: ["session_id", "sequence"], unique: true)
        }

        try migrator.migrate(writer)
    }
}
