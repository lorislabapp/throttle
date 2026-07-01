import Foundation
import GRDB

/// Attributes prompt-cache "recoverable misses" to a likely CAUSE, so Throttle can
/// go from "€X wasted re-writing a warm cache" to "€X wasted — mostly model-swaps"
/// or "prefix churn". A recoverable miss = a big cache WRITE (`cache_create` > 10k)
/// that landed < 5 min after the prior same-session turn — it should have been a
/// cheap 0.10× READ but got billed at the 1.25× write rate because the cached prefix
/// changed. Same detection threshold as `StatsDataService.recoverableMissCostEUR`;
/// this adds the attribution.
///
/// Discriminator (from usage events alone): compare the miss event's model to the
/// PRIOR same-session event's model (via LAG). Different model → the swap itself
/// invalidated the cache (**model swap**). Same model → the prefix changed for
/// another reason (**prefix churn**: dynamic statusline/CLAUDE.md injection, a
/// mutating tool schema, context editing). We can't split those further from usage
/// events, so they aggregate under prefix churn.
enum CacheBustAnalyzer {

    struct Report: Sendable, Equatable {
        var causes: [Cause]
        var totalTokens: Int { causes.reduce(0) { $0 + $1.tokens } }
        var totalEUR: Double { causes.reduce(0) { $0 + $1.eur } }
        /// The costliest cause — drives the headline ("mostly model swaps").
        var dominant: Cause? { causes.max { $0.eur < $1.eur } }
    }

    struct Cause: Sendable, Equatable {
        let kind: Kind
        let tokens: Int
        let eur: Double
        let events: Int
    }

    enum Kind: String, Sendable {
        case modelSwap = "model_swap"
        case prefixChurn = "prefix_churn"

        var advice: String {
            switch self {
            case .modelSwap:
                return "Switching models mid-session re-writes the whole prompt cache. Pick one model per session where you can."
            case .prefixChurn:
                return "Something is mutating your prompt prefix between turns (a dynamic statusline, a changing CLAUDE.md, or a shifting tool/MCP list). Keep the prefix byte-stable to stay cached."
            }
        }
    }

    static func analyze(in db: Database, days: Int = 7, now: Date = Date()) throws -> Report {
        let cutoff = Int(now.timeIntervalSince1970) - days * 86_400
        let sql = """
            WITH lagged AS (
                SELECT
                    model AS model,
                    cache_create AS cc,
                    timestamp - LAG(timestamp) OVER (PARTITION BY session_id ORDER BY timestamp) AS gap,
                    LAG(model)      OVER (PARTITION BY session_id ORDER BY timestamp) AS prev_model
                FROM usage_events
                WHERE timestamp >= ?
            ),
            misses AS (
                SELECT \(bucketSQL("model")) AS bucket, \(bucketSQL("prev_model")) AS prev_bucket, cc
                FROM lagged
                WHERE gap IS NOT NULL AND gap >= 0 AND gap < 300 AND cc > 10000
            )
            SELECT bucket,
                   CASE WHEN bucket = prev_bucket THEN 'prefix_churn' ELSE 'model_swap' END AS cause,
                   SUM(cc) AS recoverable,
                   COUNT(*) AS n
            FROM misses
            GROUP BY bucket, cause
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [cutoff])

        // Aggregate per cause, weighting each model bucket by its input rate.
        var tokens: [Kind: Int] = [:], usd: [Kind: Double] = [:], events: [Kind: Int] = [:]
        for row in rows {
            guard let causeStr: String = row["cause"], let kind = Kind(rawValue: causeStr) else { continue }
            let bucket: String = row["bucket"] ?? ""
            let cc: Int = row["recoverable"] ?? 0
            let n: Int = row["n"] ?? 0
            tokens[kind, default: 0] += cc
            events[kind, default: 0] += n
            usd[kind, default: 0] += Double(cc) / 1_000_000.0 * inputRate(bucket) * 1.15   // 1.25× write − 0.10× read
        }
        let usdToEur = 0.93
        let causes = Kind.allKinds.compactMap { k -> Cause? in
            guard let t = tokens[k], t > 0 else { return nil }
            return Cause(kind: k, tokens: t, eur: (usd[k] ?? 0) * usdToEur, events: events[k] ?? 0)
        }
        return Report(causes: causes)
    }

    // MARK: - Helpers

    /// USD per-million input-token rate by model bucket (matches recoverableMissCostEUR).
    static func inputRate(_ bucket: String) -> Double {
        switch bucket {
        case "fable":  return 10
        case "opus":   return 5
        case "sonnet": return 3
        case "haiku":  return 1
        default:       return 3
        }
    }

    /// SQL that buckets a model-name column into a rate class (nil/unknown → 'other').
    private static func bucketSQL(_ col: String) -> String {
        """
        CASE
            WHEN lower(\(col)) LIKE '%fable%' OR lower(\(col)) LIKE '%mythos%' THEN 'fable'
            WHEN lower(\(col)) LIKE '%opus%'   THEN 'opus'
            WHEN lower(\(col)) LIKE '%sonnet%' THEN 'sonnet'
            WHEN lower(\(col)) LIKE '%haiku%'  THEN 'haiku'
            ELSE 'other'
        END
        """
    }
}

private extension CacheBustAnalyzer.Kind {
    static var allKinds: [CacheBustAnalyzer.Kind] { [.modelSwap, .prefixChurn] }
}
