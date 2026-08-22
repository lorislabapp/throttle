import Foundation
import GRDB

/// One persisted data point on the historical usage timeline.
/// Stored bucketed at 5-minute resolution to keep the table small and
/// give a smooth chart line without burning rows on every refresh().
struct UsageSnapshotRow: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "usage_snapshots"

    /// Unix timestamp rounded down to the start of a 5-minute bucket.
    var timestampBucket: Int64
    var windowKind: String        // matches WindowKind.rawValue
    var usedTokens: Int
    var capTokens: Int?           // nil if not yet calibrated at write time

    enum CodingKeys: String, CodingKey {
        case timestampBucket = "timestamp_bucket"
        case windowKind = "window_kind"
        case usedTokens = "used_tokens"
        case capTokens = "cap_tokens"
    }

    static let bucketSizeSeconds: Int64 = 300  // 5 minutes
}

/// One record of bytes saved by a token-optimization hook firing.
struct TokoptSavingsRow: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "tokopt_savings"

    var id: Int64?
    var timestamp: Int64
    var hook: String              // e.g. "session-start-router", "pre-compact"
    var baselineBytes: Int
    var actualBytes: Int

    enum CodingKeys: String, CodingKey {
        case id, timestamp, hook
        case baselineBytes = "baseline_bytes"
        case actualBytes = "actual_bytes"
    }

    /// Hooks that ADD context rather than remove it. Their "baseline" is a
    /// counterfactual nobody would have lived — "without routing you would have
    /// loaded every memory file" — and counting it as a saving inflated the
    /// headline figure by ~26× (measured 2026-08-22: 291 KB claimed per session
    /// against 226 bytes actually emitted, on top of an index that loads either
    /// way). A tool that overstates its own gains cannot be trusted on anything
    /// else it measures.
    static let injectingHooks: Set<String> = ["session-start-router"]

    var isInjection: Bool { Self.injectingHooks.contains(hook) }

    /// Bytes this hook kept out of context. Zero for injecting hooks: they spend
    /// context to spend it better, which is worth doing and is not a saving.
    var savedBytes: Int { isInjection ? 0 : max(0, baselineBytes - actualBytes) }

    /// What an injecting hook cost. Reported separately so the ledger stays
    /// honest in both directions.
    var injectedBytes: Int { isInjection ? actualBytes : 0 }

    /// Bytes saved, discounted for what breaking the prompt cache costs.
    ///
    /// Anthropic bills a cache read at 0.1× the base input rate and a cache write
    /// at 1.25× (5-minute TTL). Trimming rewrites the prefix, so the turn after a
    /// trim pays full write price on the whole remaining prompt while the
    /// untrimmed session would have paid 0.1× — the trim only pays for itself
    /// after enough turns. CMV measures break-even at ~10 turns for tool-heavy
    /// sessions and ~40 for conversational ones, and concludes that trimming a
    /// low-tool session is economically counterproductive.
    ///
    /// This is the honest floor: what the trim is worth on the very next turn,
    /// before amortisation. A session that continues long enough earns the rest.
    var cacheAwareSavedBytes: Int {
        guard savedBytes > 0 else { return 0 }
        let cacheRead = 0.1, cacheWrite = 1.25
        let penalty = Double(actualBytes) * (cacheWrite - cacheRead)
        return max(0, Int(Double(savedBytes) * cacheRead - penalty))
    }
}

/// Cumulative Codex usage for one rollout session.
///
/// Keyed by session rather than appended per observation on purpose. Codex
/// reports a session's totals, not the delta since the last read, so appending
/// would re-add the whole history every refresh — the shape of the double-count
/// that migration v6 had to undo. Upserting the latest totals makes re-reading
/// the same rollout idempotent by construction.
struct CodexUsageRow: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "codex_usage"

    var sessionId: String
    var observedAt: Int64
    var inputTokens: Int
    var cachedInputTokens: Int
    var cacheWriteInputTokens: Int
    var outputTokens: Int
    var reasoningOutputTokens: Int
    var totalTokens: Int
    var contextWindow: Int?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case observedAt = "observed_at"
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case cacheWriteInputTokens = "cache_write_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
        case contextWindow = "context_window"
    }

    /// What actually had to be sent to the provider: cache reads are served from
    /// the cache, so counting them as fresh input overstates the work done.
    var uncachedInputTokens: Int { max(0, inputTokens - cachedInputTokens) }
}
