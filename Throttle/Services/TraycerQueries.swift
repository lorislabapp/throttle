import Foundation
import GRDB

/// Traycer attribution: joins the OTel event stream in `traycer_events` to the
/// token/cost rows in `usage_events` by `session.id`, producing true **€ per
/// skill** for one project. Measure-only — read path only.
///
/// Window attribution: within a session (ordered by `sequence`), each
/// `skill_activated` event owns the interval `[ts, next_event_ts)`. The EUR cost
/// of the `usage_events` that land in that interval is attributed to the skill —
/// the same consecutive-delta idea as `TestOutcomeStore`'s €/green-run, done in
/// SQL via `LEAD()` + a correlated `SUM(eurRowExpr)` subquery.
extension StatsDataService {

    struct SkillCost: Sendable, Equatable {
        let skill: String
        let fires: Int
        let eur: Double
    }

    /// €/skill for one project over the last `days`. Sessions are scoped to the
    /// project through `file_state.session_id` (indexed by migration v5), so this
    /// stays a B-tree lookup, not a scan.
    static func traycerSkillCosts(in db: Database, project encodedProject: String,
                                  days: Int = 14, now: Date = Date()) throws -> [SkillCost] {
        let cutoff = Int(now.timeIntervalSince1970) - days * 86_400
        let sql = """
            WITH ev AS (
                SELECT session_id, event_type, skill_name, ts,
                       LEAD(ts) OVER (PARTITION BY session_id ORDER BY sequence) AS next_ts
                FROM traycer_events
                WHERE ts >= ?
                  AND session_id IN (SELECT session_id FROM file_state WHERE encoded_project = ?)
            )
            SELECT ev.skill_name AS s,
                   COUNT(*) AS fires,
                   SUM((
                       SELECT COALESCE(SUM(\(eurRowExpr)), 0)
                       FROM usage_events u
                       WHERE u.session_id = ev.session_id
                         AND u.timestamp >= ev.ts
                         AND (ev.next_ts IS NULL OR u.timestamp < ev.next_ts)
                   )) AS eur
            FROM ev
            WHERE ev.event_type = 'skill_activated' AND ev.skill_name IS NOT NULL
            GROUP BY ev.skill_name
            ORDER BY eur DESC, fires DESC
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [cutoff, encodedProject])
        return rows.compactMap { r in
            guard let s: String = r["s"] else { return nil }
            return SkillCost(skill: s, fires: r["fires"] ?? 0, eur: r["eur"] ?? 0)
        }
    }

    /// Whether any Traycer events exist for this project (drives readout visibility).
    static func traycerHasData(in db: Database, project encodedProject: String) throws -> Bool {
        let n = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM traycer_events
            WHERE session_id IN (SELECT session_id FROM file_state WHERE encoded_project = ?)
            """, arguments: [encodedProject]) ?? 0
        return n > 0
    }
}
