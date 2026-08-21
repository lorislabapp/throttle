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

    var savedBytes: Int { max(0, baselineBytes - actualBytes) }
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
