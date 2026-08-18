import Foundation
import GRDB

/// Retro-attribution: which recent frontier sessions had a *bounded, local-safe
/// profile* — the shape of work (few turns, small fresh context, small output)
/// that a 3–4B on-device model serves credibly?
///
/// This is advisory, never a claim. A session that succeeded on Claude does not
/// prove a 4B would have succeeded (the counterfactual is unproven — the honest
/// way to close it is a shadow replay, which this report is the entry point for).
/// So the UI must present these as "local-safe *profile*" with `≈`/est framing,
/// and the thresholds below are deliberately conservative: they describe the
/// bounded-artifact task classes (title, summary, extraction, quick question,
/// commit message) where small models are strongest, and exclude anything that
/// smells like multi-file or long-reasoning work.
///
/// Everything is computed from usage.db — no proxy, no cloud, no transcript
/// content is read.
enum LocalCandidateService {

    // Conservative "bounded artifact" profile. Product policy, not literature
    // constants — tighten before ever loosening.
    static let windowDays = 7
    /// Only completed sessions: still-active ones can't be judged yet.
    static let settleSeconds: Int64 = 30 * 60
    /// ≤ this many API turns — a single bounded ask, not an agentic loop.
    static let maxTurns = 4
    /// Total output stays artifact-sized (a title/summary/extraction, not code).
    static let maxOutputTokens = 1_500
    /// …but a real artifact was produced: zero-output rows are aborted/empty
    /// sessions, not tasks — recommending "Local" for those would be noise.
    static let minOutputTokens = 50
    /// Fresh (non-cache-read) input a small local model could realistically hold.
    static let maxFreshInputTokens = 8_000
    /// Wall-clock bound: quick ask, not a work session.
    static let maxDurationSeconds: Int64 = 15 * 60

    struct Candidate: Sendable, Identifiable {
        var id: String { sessionId }
        let sessionId: String
        let projectName: String?
        let turns: Int
        let outputTokens: Int
        let freshInputTokens: Int
        let weightedTokens: Int
        let costEUR: Double
        let lastActivity: Int64
    }

    struct Report: Sendable {
        let candidates: [Candidate]
        /// All sessions active in the window — the honest denominator.
        let scannedSessions: Int
        var avoidableEUR: Double { candidates.reduce(0) { $0 + $1.costEUR } }
        var avoidableWeightedTokens: Int { candidates.reduce(0) { $0 + $1.weightedTokens } }
        static let empty = Report(candidates: [], scannedSessions: 0)
    }

    /// Runs inside `database.read { }` off the main actor, like every cockpit query.
    static func scan(in db: Database, now: Date = Date()) throws -> Report {
        let nowTs = Int64(now.timeIntervalSince1970)
        let windowStart = nowTs - Int64(windowDays) * 86_400
        let settledBefore = nowTs - settleSeconds

        let scanned = try Int.fetchOne(db, sql: """
            SELECT COUNT(DISTINCT session_id) FROM usage_events WHERE timestamp >= ?
            """, arguments: [windowStart]) ?? 0

        let sql = """
            SELECT session_id,
                   COUNT(*)                                   AS turns,
                   MAX(timestamp)                              AS last_ts,
                   SUM(output_tokens)                          AS out_tok,
                   SUM(input_tokens + cache_create)            AS fresh_in,
                   SUM(input_tokens + output_tokens + cache_create + (cache_read / 10)) AS weighted,
                   SUM(\(StatsDataService.eurRowExpr))         AS eur
            FROM usage_events
            WHERE timestamp >= ?
            GROUP BY session_id
            HAVING last_ts <= ?
               AND turns <= ?
               AND out_tok BETWEEN ? AND ?
               AND fresh_in <= ?
               AND (last_ts - MIN(timestamp)) <= ?
            ORDER BY last_ts DESC
            LIMIT 50
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [
            windowStart, settledBefore, maxTurns, minOutputTokens, maxOutputTokens,
            maxFreshInputTokens, maxDurationSeconds,
        ])
        let candidates: [Candidate] = try rows.compactMap { row in
            guard let sid: String = row["session_id"] else { return nil }
            let path = try StatsDataService.cockpitSessionPath(in: db, sessionId: sid)
            return Candidate(
                sessionId: sid,
                projectName: path.flatMap(cockpitProjectName(fromJSONLPath:)),
                turns: row["turns"] ?? 0,
                outputTokens: row["out_tok"] ?? 0,
                freshInputTokens: row["fresh_in"] ?? 0,
                weightedTokens: row["weighted"] ?? 0,
                costEUR: row["eur"] ?? 0,
                lastActivity: row["last_ts"] ?? 0
            )
        }
        return Report(candidates: candidates, scannedSessions: scanned)
    }
}
