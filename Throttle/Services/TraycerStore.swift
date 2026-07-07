import Foundation
import GRDB

/// GRDB row for `traycer_events`. Insert policy is **IGNORE** so a replayed OTLP
/// batch (the exporter retries transient failures) never double-counts —
/// idempotency rides on the `UNIQUE(session_id, sequence)` index.
struct TraycerRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "traycer_events"
    static let persistenceConflictPolicy = PersistenceConflictPolicy(insert: .ignore)

    var id: Int64?
    var session_id: String
    var sequence: Int
    var ts: Int
    var event_type: String
    var tool_name: String?
    var skill_name: String?
    var full_command: String?
    var decision: String?
    var success: Bool?

    init(_ e: TraycerEvent) {
        session_id = e.sessionId
        sequence = e.sequence
        ts = e.tsUnixSeconds
        event_type = e.eventName
        tool_name = e.toolName
        skill_name = e.skillName
        full_command = e.fullCommand
        decision = e.decision
        success = e.success
    }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Batched writer + read queries for Traycer events. All writes are fail-open:
/// a DB error is swallowed so the receiver can never disturb Claude Code's
/// telemetry path.
enum TraycerStore {

    /// Batch-insert decoded events. Returns the count of rows *actually* written
    /// (IGNORE-conflicts don't count), so callers can log real ingest.
    @discardableResult
    static func insert(_ events: [TraycerEvent], into writer: any DatabaseWriter) -> Int {
        guard !events.isEmpty else { return 0 }
        return (try? writer.write { db in
            let before = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM traycer_events") ?? 0
            for e in events { try TraycerRow(e).insert(db) }
            let after = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM traycer_events") ?? 0
            return after - before
        }) ?? 0
    }

    /// Distinct skill activations in the last `days` with fire counts (measure-only).
    struct SkillCount: Sendable { let skill: String; let count: Int }
    static func skillCounts(in db: Database, days: Int = 14, now: Date = Date()) throws -> [SkillCount] {
        let cutoff = Int(now.timeIntervalSince1970) - days * 86_400
        let rows = try Row.fetchAll(db, sql: """
            SELECT skill_name AS s, COUNT(*) AS c
            FROM traycer_events
            WHERE event_type = 'skill_activated' AND skill_name IS NOT NULL AND ts >= ?
            GROUP BY skill_name ORDER BY c DESC
            """, arguments: [cutoff])
        return rows.compactMap { r in (r["s"] as String?).map { SkillCount(skill: $0, count: r["c"] ?? 0) } }
    }

    /// All events for a session, oldest first — the basis for time-window cost
    /// attribution (built in the readout, §4).
    static func events(in db: Database, sessionId: String) throws -> [TraycerRow] {
        try TraycerRow
            .filter(Column("session_id") == sessionId)
            .order(Column("sequence"))
            .fetchAll(db)
    }
}
