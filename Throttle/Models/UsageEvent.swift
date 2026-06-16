import Foundation
import GRDB

struct UsageEvent: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    var id: Int64?
    var sessionId: String
    var timestamp: Int64        // unix seconds
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreate: Int
    var cacheRead: Int
    var serviceTier: String?

    static let databaseTableName = "usage_events"

    /// Ingestion is idempotent: a re-scanned event that already exists (same
    /// natural key, enforced by idx_usage_natural) is silently ignored instead
    /// of inserted again. Prevents the ~12% double-count from file re-scans.
    static let persistenceConflictPolicy = PersistenceConflictPolicy(insert: .ignore)

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case timestamp
        case model
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreate = "cache_create"
        case cacheRead = "cache_read"
        case serviceTier = "service_tier"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreate + cacheRead
    }
}
