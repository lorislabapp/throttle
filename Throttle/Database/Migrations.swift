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

        // v8: web_fetches — one row per web_render, so a repeat render of the same
        // URL within a TTL can be served from the cached extracted text (stored in
        // ContentStore by content_hash) instead of spinning up WKWebView again.
        // session_id is nullable (the render request doesn't currently carry one);
        // when populated later it joins to usage_events for €-per-render, Traycer-style.
        migrator.registerMigration("v8_web_fetches") { db in
            try db.create(table: "web_fetches") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url_normalized", .text).notNull()
                t.column("content_hash", .text).notNull()   // SHA-256 of extracted text → ContentStore key
                t.column("fetched_at", .integer).notNull()
                t.column("render_ms", .integer)
                t.column("text_bytes", .integer)
                t.column("session_id", .text)
            }
            try db.create(index: "idx_web_fetches_url", on: "web_fetches", columns: ["url_normalized"])
            try db.create(index: "idx_web_fetches_at", on: "web_fetches", columns: ["fetched_at"])
        }

        // v9: codex_usage — Codex was metered live in the menu bar and nowhere
        // else, so there was no 7-day Codex cost, no trend, and `get_session_cost`
        // reported a Claude-only figure as if it were the whole bill.
        //
        // Codex rollouts carry CUMULATIVE totals for a session, not per-turn
        // deltas. Appending them to `usage_events` would re-add a session's whole
        // history on every refresh — the same shape as the ~12% double-count that
        // v6 had to migrate away. So this table is keyed by session and the write
        // is an UPSERT of the latest totals: re-reading the same rollout a hundred
        // times converges on one row instead of accumulating. Deltas, when needed,
        // are derived at read time.
        migrator.registerMigration("v9_codex_usage") { db in
            try db.create(table: "codex_usage") { t in
                t.primaryKey("session_id", .text)          // rollout UUID
                t.column("observed_at", .integer).notNull() // rollout mtime, seconds
                t.column("input_tokens", .integer).notNull().defaults(to: 0)
                t.column("cached_input_tokens", .integer).notNull().defaults(to: 0)
                t.column("cache_write_input_tokens", .integer).notNull().defaults(to: 0)
                t.column("output_tokens", .integer).notNull().defaults(to: 0)
                t.column("reasoning_output_tokens", .integer).notNull().defaults(to: 0)
                t.column("total_tokens", .integer).notNull().defaults(to: 0)
                t.column("context_window", .integer)
            }
            try db.create(index: "idx_codex_usage_at", on: "codex_usage", columns: ["observed_at"])
        }

        // A streaming response is written twice: once partial, once final. The two
        // rows share session, timestamp, model AND both cache figures, and differ
        // only in output_tokens — so the v6 unique index, which includes
        // output_tokens, sees two distinct rows and lets both through. Every cache
        // number in the pair is then counted twice.
        //
        // Measured 2026-08-22: 18 380 such groups holding 1 438 011 853 duplicated
        // cache tokens, roughly 0.9% of everything in the table. v6 removed a ~12%
        // full-row duplication; this is the remainder it could not see.
        //
        // The FINAL row is the one to keep — it carries the complete
        // output_tokens — so this deletes by MAX(output_tokens), not MIN(id).
        // Input tokens are part of the key: a genuine second call in the same
        // second with different inputs is real traffic, not a duplicate.
        migrator.registerMigration("v10_dedupe_streaming_partials") { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_usage_stream_tmp
                ON usage_events(session_id, timestamp, model,
                                input_tokens, cache_create, cache_read, output_tokens)
                """)
            try db.execute(sql: """
                DELETE FROM usage_events
                WHERE (cache_create > 0 OR cache_read > 0)
                  AND id NOT IN (
                    SELECT id FROM usage_events e
                    WHERE e.output_tokens = (
                        SELECT MAX(output_tokens) FROM usage_events x
                        WHERE x.session_id = e.session_id AND x.timestamp = e.timestamp
                          AND x.model = e.model AND x.input_tokens = e.input_tokens
                          AND x.cache_create = e.cache_create AND x.cache_read = e.cache_read
                    )
                  )
                """)
            try db.execute(sql: "DROP INDEX IF EXISTS idx_usage_stream_tmp")
        }

        try migrator.migrate(writer)
    }
}
