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
