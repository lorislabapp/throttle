import Foundation
import GRDB

/// Cockpit-specific read queries: per-session tokens/cost/split, and a recent
/// burn-rate sample for the predictive forecast. Kept as an extension on
/// `StatsDataService` so the model rate table + weighted-token formula stay in
/// one place (no drift). All methods are `nonisolated` and run inside
/// `database.read { }` off the main actor.
extension StatsDataService {

    // The weighted-token expression used everywhere: cache reads at 10%.
    fileprivate static let weightedExpr =
        "input_tokens + output_tokens + cache_create + (cache_read / 10)"

    /// Per-row EUR cost expression over `usage_events` columns (unqualified, so it
    /// resolves against whatever `usage_events` alias is in scope). Mirrors the
    /// Swift rates in `cockpitSessionCostEUR` exactly (USD/MTok → *0.93 EUR,
    /// cache_create at 1.25×, cache_read at 0.10×). Kept as a string so
    /// window-scoped attribution (Traycer) can SUM it inside a correlated
    /// subquery. `cockpitSessionCostEUR` stays the source of truth for the rates.
    static let eurRowExpr = ModelPricing.sqlRowEurExpr()

    /// The session with the most recent activity — the one the user is in.
    static func cockpitCurrentSessionId(in db: Database) throws -> String? {
        try String.fetchOne(db, sql: """
            SELECT session_id FROM usage_events ORDER BY timestamp DESC LIMIT 1
            """)
    }

    /// Weighted tokens consumed by one session.
    static func cockpitSessionTokens(in db: Database, sessionId: String) throws -> Int {
        let sql = "SELECT COALESCE(SUM(\(weightedExpr)), 0) AS w FROM usage_events WHERE session_id = ?"
        return try Row.fetchOne(db, sql: sql, arguments: [sessionId])?["w"] ?? 0
    }

    /// Approximate API cost (EUR) for one session. Mirrors
    /// `extrapolatedCostEUR` exactly, scoped to a single session.
    static func cockpitSessionCostEUR(in db: Database, sessionId: String) throws -> Double {
        let sql = """
            SELECT
                \(ModelPricing.sqlBucketExpr("model")) AS bucket,
                SUM(input_tokens) AS i, SUM(output_tokens) AS o,
                SUM(cache_create) AS cc, SUM(cache_read) AS cr
            FROM usage_events WHERE session_id = ? GROUP BY bucket
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [sessionId])
        var usd: Double = 0
        for row in rows {
            let bucket: String = row["bucket"] ?? ""
            let i: Int = row["i"] ?? 0, o: Int = row["o"] ?? 0
            let cc: Int = row["cc"] ?? 0, cr: Int = row["cr"] ?? 0
            let (inRate, outRate): (Double, Double)
            switch bucket {   // official USD/MTok rates, refreshed 2026-06-11
            case "fable":  (inRate, outRate) = (10, 50)
            case "opus":   (inRate, outRate) = (5, 25)
            case "sonnet": (inRate, outRate) = (3, 15)
            case "haiku":  (inRate, outRate) = (1, 5)
            default:       (inRate, outRate) = (3, 15)
            }
            let m = 1_000_000.0
            usd += Double(i)/m*inRate + Double(o)/m*outRate
                 + Double(cc)/m*inRate*1.25 + Double(cr)/m*inRate*0.10
        }
        return usd * 0.93
    }

    /// Model split (weighted tokens per tier) for one session.
    static func cockpitModelSplitForSession(in db: Database, sessionId: String) throws -> [ModelSlice] {
        let sql = """
            SELECT
                CASE
                    WHEN lower(model) LIKE '%opus%'   THEN 'opus'
                    WHEN lower(model) LIKE '%sonnet%' THEN 'sonnet'
                    WHEN lower(model) LIKE '%haiku%'  THEN 'haiku'
                    ELSE 'other'
                END AS bucket,
                SUM(\(weightedExpr)) AS weighted
            FROM usage_events WHERE session_id = ? GROUP BY bucket
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [sessionId])
        return rows.compactMap { row in
            guard let b: String = row["bucket"] else { return nil }
            let w: Int = row["weighted"] ?? 0
            let tier: ModelTier
            switch b {
            case "opus":   tier = .opus
            case "sonnet": tier = .sonnet
            case "haiku":  tier = .haiku
            default:       tier = .other
            }
            return ModelSlice(tier: tier, weightedTokens: w)
        }
    }

    // A 15-minute global burn sample used to live here for a cockpit forecast cell
    // that was never built. The predictive nudge that did ship
    // (`ThresholdNotifier.forecastCapETA`) derives its rate from the binding
    // percentage and re-anchors every 2 minutes, so it never needed this query.

    /// Recent sessions (by last activity) — the analytics half of multi-session.
    /// Execution stays a single terminal; the cockpit only *attributes* cost and
    /// offers a `claude --resume <id>` passthrough. No tabs, no session store.
    struct RecentSession: Sendable {
        let id: String
        let lastActivity: Int64
        let weightedTokens: Int
    }

    static func cockpitRecentSessions(in db: Database, limit: Int = 6) throws -> [RecentSession] {
        let sql = """
            SELECT session_id, MAX(timestamp) AS last_ts, SUM(\(weightedExpr)) AS w
            FROM usage_events
            GROUP BY session_id
            ORDER BY last_ts DESC
            LIMIT ?
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [limit])
        return rows.compactMap { row in
            guard let id: String = row["session_id"], let ts: Int64 = row["last_ts"] else { return nil }
            return RecentSession(id: id, lastActivity: ts, weightedTokens: row["w"] ?? 0)
        }
    }

    /// The JSONL path for a session, so we can name it by its project (repo).
    static func cockpitSessionPath(in db: Database, sessionId: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT path FROM file_state WHERE path LIKE ? LIMIT 1",
                            arguments: ["%/\(sessionId).jsonl"])
    }
}
