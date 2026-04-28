import Foundation
import GRDB

/// Read-only computations for the Stats tab. Pulls from `usage_events`,
/// `usage_snapshots`, and `tokopt_savings`. All methods are nonisolated
/// so the views can dispatch them off the main actor when fetching.
enum StatsDataService {
    enum Range: Int, CaseIterable, Identifiable {
        case last24h = 24
        case last7d  = 168
        case last30d = 720
        case all     = 0
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .last24h: return "24h"
            case .last7d:  return "7d"
            case .last30d: return "30d"
            case .all:     return "All"
            }
        }
        /// Cutoff seconds-since-epoch. Returns 0 for .all.
        func cutoff(now: Date = Date()) -> Int64 {
            guard rawValue > 0 else { return 0 }
            return Int64(now.timeIntervalSince1970) - Int64(rawValue) * 3600
        }
    }

    // MARK: - Line chart data

    struct LinePoint: Hashable, Sendable {
        let timestamp: Date
        let kind: WindowKind
        let percent: Double  // 0...1; 0 if not calibrated at the time
    }

    static func linePoints(in db: Database, range: Range, now: Date = Date()) throws -> [LinePoint] {
        let cutoff = range.cutoff(now: now)
        let sql: String
        if cutoff > 0 {
            sql = """
            SELECT timestamp_bucket, window_kind, used_tokens, cap_tokens
            FROM usage_snapshots
            WHERE timestamp_bucket >= ?
            ORDER BY timestamp_bucket ASC
            """
        } else {
            sql = """
            SELECT timestamp_bucket, window_kind, used_tokens, cap_tokens
            FROM usage_snapshots
            ORDER BY timestamp_bucket ASC
            """
        }
        let rows = cutoff > 0
            ? try Row.fetchAll(db, sql: sql, arguments: [cutoff])
            : try Row.fetchAll(db, sql: sql)
        return rows.compactMap { r in
            guard let kindStr: String = r["window_kind"],
                  let kind = WindowKind(rawValue: kindStr),
                  let bucket: Int64 = r["timestamp_bucket"],
                  let used: Int = r["used_tokens"] else { return nil }
            let cap = r["cap_tokens"] as Int?
            let pct: Double
            if let c = cap, c > 0 {
                pct = min(1.0, Double(used) / Double(c))
            } else {
                pct = 0
            }
            return LinePoint(
                timestamp: Date(timeIntervalSince1970: TimeInterval(bucket)),
                kind: kind,
                percent: pct
            )
        }
    }

    // MARK: - Hour-of-day heatmap

    struct HeatCell: Hashable, Sendable {
        let dayOfWeek: Int   // 1 (Sunday) ... 7 (Saturday)
        let hour: Int        // 0...23
        let weightedTokens: Int
    }

    static func heatmap(in db: Database, range: Range, now: Date = Date()) throws -> [HeatCell] {
        let cutoff = range.cutoff(now: now)
        let where_ = cutoff > 0 ? "WHERE timestamp >= ?" : ""
        let sql = """
            SELECT
                CAST(strftime('%w', datetime(timestamp, 'unixepoch', 'localtime')) AS INTEGER) + 1 AS dow,
                CAST(strftime('%H', datetime(timestamp, 'unixepoch', 'localtime')) AS INTEGER) AS h,
                SUM(input_tokens + output_tokens + cache_create + (cache_read / 10)) AS weighted
            FROM usage_events
            \(where_)
            GROUP BY dow, h
            """
        let rows = cutoff > 0
            ? try Row.fetchAll(db, sql: sql, arguments: [cutoff])
            : try Row.fetchAll(db, sql: sql)
        return rows.compactMap {
            guard let d: Int = $0["dow"], let h: Int = $0["h"] else { return nil }
            let w: Int = $0["weighted"] ?? 0
            return HeatCell(dayOfWeek: d, hour: h, weightedTokens: w)
        }
    }

    // MARK: - Model split

    struct ModelSlice: Hashable, Sendable, Identifiable {
        let tier: ModelTier
        let weightedTokens: Int
        var id: ModelTier { tier }
    }

    static func modelSplit(in db: Database, range: Range, now: Date = Date()) throws -> [ModelSlice] {
        let cutoff = range.cutoff(now: now)
        let where_ = cutoff > 0 ? "WHERE timestamp >= ?" : ""
        let sql = """
            SELECT
                CASE
                    WHEN lower(model) LIKE '%opus%'   THEN 'opus'
                    WHEN lower(model) LIKE '%sonnet%' THEN 'sonnet'
                    WHEN lower(model) LIKE '%haiku%'  THEN 'haiku'
                    ELSE 'other'
                END AS bucket,
                SUM(input_tokens + output_tokens + cache_create + (cache_read / 10)) AS weighted
            FROM usage_events
            \(where_)
            GROUP BY bucket
            """
        let rows = cutoff > 0
            ? try Row.fetchAll(db, sql: sql, arguments: [cutoff])
            : try Row.fetchAll(db, sql: sql)
        return rows.compactMap {
            guard let b: String = $0["bucket"] else { return nil }
            let w: Int = $0["weighted"] ?? 0
            let tier: ModelTier = {
                switch b {
                case "opus":   return .opus
                case "sonnet": return .sonnet
                case "haiku":  return .haiku
                default:       return .other
                }
            }()
            return ModelSlice(tier: tier, weightedTokens: w)
        }
    }

    // MARK: - Cost extrapolation

    /// Approximate API cost for the given range, in EUR.
    /// Anthropic public prices (April 2026, USD per million tokens; we apply
    /// a flat 0.93 EUR/USD conversion to keep this offline-friendly):
    ///   Opus:   $15 input / $75 output
    ///   Sonnet:  $3 input / $15 output
    ///   Haiku:   $0.80 input / $4 output
    /// Cache reads are billed at ~10% of input rate, cache writes at 125%.
    static func extrapolatedCostEUR(in db: Database, range: Range, now: Date = Date()) throws -> Double {
        let cutoff = range.cutoff(now: now)
        let where_ = cutoff > 0 ? "WHERE timestamp >= ?" : ""
        let sql = """
            SELECT
                CASE
                    WHEN lower(model) LIKE '%opus%'   THEN 'opus'
                    WHEN lower(model) LIKE '%sonnet%' THEN 'sonnet'
                    WHEN lower(model) LIKE '%haiku%'  THEN 'haiku'
                    ELSE 'other'
                END AS bucket,
                SUM(input_tokens) AS i,
                SUM(output_tokens) AS o,
                SUM(cache_create) AS cc,
                SUM(cache_read) AS cr
            FROM usage_events
            \(where_)
            GROUP BY bucket
            """
        let rows = cutoff > 0
            ? try Row.fetchAll(db, sql: sql, arguments: [cutoff])
            : try Row.fetchAll(db, sql: sql)
        let usdToEur: Double = 0.93
        var totalUsd: Double = 0
        for row in rows {
            let bucket: String = row["bucket"] ?? ""
            let i: Int = row["i"] ?? 0
            let o: Int = row["o"] ?? 0
            let cc: Int = row["cc"] ?? 0
            let cr: Int = row["cr"] ?? 0
            let (inRate, outRate): (Double, Double)
            switch bucket {
            case "opus":   (inRate, outRate) = (15, 75)
            case "sonnet": (inRate, outRate) = (3, 15)
            case "haiku":  (inRate, outRate) = (0.80, 4)
            default:       (inRate, outRate) = (3, 15)  // unknown → assume Sonnet rates
            }
            let perMillion = 1_000_000.0
            let input = Double(i) / perMillion * inRate
            let output = Double(o) / perMillion * outRate
            let cacheWrite = Double(cc) / perMillion * inRate * 1.25
            let cacheRead = Double(cr) / perMillion * inRate * 0.10
            totalUsd += input + output + cacheWrite + cacheRead
        }
        return totalUsd * usdToEur
    }

    // MARK: - Per-project breakdown

    struct ProjectSlice: Hashable, Sendable, Identifiable {
        let projectName: String   // last path component, e.g. "Throttle"
        let projectPath: String   // decoded full path, e.g. "/Users/kevin/GitHub/Throttle"
        let weightedTokens: Int
        var id: String { projectPath }
    }

    /// Top N projects by token spend in the given range. Joins
    /// `usage_events` by `session_id` to `file_state` via JSONL path.
    /// Returns at most `limit` rows.
    static func topProjects(in db: Database, range: Range, limit: Int = 5, now: Date = Date()) throws -> [ProjectSlice] {
        let cutoff = range.cutoff(now: now)
        let where_ = cutoff > 0 ? "WHERE e.timestamp >= ?" : ""
        let sql = """
            SELECT fs.path AS path,
                   SUM(e.input_tokens + e.output_tokens + e.cache_create + (e.cache_read / 10)) AS weighted
            FROM usage_events e
            JOIN file_state fs ON fs.path LIKE '%/' || e.session_id || '.jsonl'
            \(where_)
            GROUP BY fs.path
            """
        let rows = cutoff > 0
            ? try Row.fetchAll(db, sql: sql, arguments: [cutoff])
            : try Row.fetchAll(db, sql: sql)

        // Aggregate by directory (multiple sessions per project).
        var byProject: [String: Int] = [:]
        for row in rows {
            guard let path: String = row["path"] else { continue }
            let weighted: Int = row["weighted"] ?? 0
            let dir = (path as NSString).deletingLastPathComponent
            byProject[dir, default: 0] += weighted
        }

        return byProject
            .map { (encoded, tokens) -> ProjectSlice in
                let decoded = decodeClaudeProjectPath(encoded)
                let name = (decoded as NSString).lastPathComponent
                return ProjectSlice(
                    projectName: name.isEmpty ? "(unknown)" : name,
                    projectPath: decoded,
                    weightedTokens: tokens
                )
            }
            .sorted { $0.weightedTokens > $1.weightedTokens }
            .prefix(limit)
            .map { $0 }
    }

    /// Convert Claude Code's encoded project directory back to its
    /// real filesystem path. Format:
    ///   /Users/kevin/.claude/projects/-Users-kevin-GitHub-Throttle
    /// → /Users/kevin/GitHub/Throttle
    private static func decodeClaudeProjectPath(_ projectsSubdir: String) -> String {
        let encoded = (projectsSubdir as NSString).lastPathComponent
        // Encoded form: leading "-" then path with "/" replaced by "-".
        guard encoded.hasPrefix("-") else { return projectsSubdir }
        let withoutLead = String(encoded.dropFirst())
        return "/" + withoutLead.replacingOccurrences(of: "-", with: "/")
    }

    // MARK: - Hook savings

    static func savedBytesThisWeek(in db: Database, now: Date = Date()) throws -> Int {
        let cutoff = Int64(now.timeIntervalSince1970) - 7 * 24 * 3600
        let row = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(MAX(0, baseline_bytes - actual_bytes)), 0) AS saved
            FROM tokopt_savings
            WHERE timestamp >= ?
            """, arguments: [cutoff])
        return row?["saved"] ?? 0
    }

    /// Approximate token savings (4 bytes per token average for English-heavy logs).
    static func savedTokensThisWeek(in db: Database, now: Date = Date()) throws -> Int {
        let bytes = try savedBytesThisWeek(in: db, now: now)
        return bytes / 4
    }
}
