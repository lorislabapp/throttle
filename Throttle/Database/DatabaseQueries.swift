import Foundation
import GRDB

enum DatabaseQueries {
    /// Cache reads are weighted at 1/10 of regular input tokens — matches Anthropic's
    /// billing weight for prompt-caching reads, which is empirically what the consumer
    /// Pro/Max weekly limit appears to track. Without this weighting, Throttle
    /// systematically over-counts vs claude.ai's displayed % for cache-heavy sessions.
    /// The constant lives in SQL because GRDB's SUM() needs a single expression.
    private static let weightedTokenSumExpr =
        "input_tokens + output_tokens + cache_create + (cache_read / 10)"

    static func totalTokens(in db: Database, sinceTimestamp: Int64) throws -> Int {
        let row = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(\(weightedTokenSumExpr)), 0) AS total
            FROM usage_events
            WHERE timestamp > ?
            """, arguments: [sinceTimestamp])
        return row?["total"] ?? 0
    }

    static func totalTokens(
        in db: Database,
        sinceTimestamp: Int64,
        modelTier: ModelTier
    ) throws -> Int {
        var sql = """
            SELECT COALESCE(SUM(\(weightedTokenSumExpr)), 0) AS total
            FROM usage_events
            WHERE timestamp > ?
            """
        let args: [(any DatabaseValueConvertible)] = [sinceTimestamp]
        switch modelTier {
        case .opus:
            sql += " AND lower(model) LIKE '%opus%'"
        case .sonnet:
            sql += " AND lower(model) LIKE '%sonnet%'"
        case .haiku:
            sql += " AND lower(model) LIKE '%haiku%'"
        case .other:
            break
        }
        let row = try Row.fetchOne(db, sql: sql, arguments: StatementArguments(args))
        return row?["total"] ?? 0
    }

    static func calibration(in db: Database, kind: WindowKind) throws -> Calibration? {
        try Calibration.fetchOne(db, key: kind.rawValue)
    }

    static func upsertCalibration(
        in db: Database,
        kind: WindowKind,
        capTokens: Int,
        source: String
    ) throws {
        let cal = Calibration(
            windowKind: kind.rawValue,
            capTokens: capTokens,
            source: source,
            updatedAt: Int64(Date().timeIntervalSince1970)
        )
        try cal.save(db)
    }

    static func setting(in db: Database, key: String) throws -> String? {
        try AppSetting.fetchOne(db, key: key)?.value
    }

    static func setSetting(in db: Database, key: String, value: String) throws {
        try AppSetting(key: key, value: value).save(db)
    }

    static func fileState(in db: Database, path: String) throws -> FileState? {
        try FileState.fetchOne(db, key: path)
    }

    static func upsertFileState(
        in db: Database,
        path: String,
        offset: Int64,
        mtime: Int64
    ) throws {
        try FileState(path: path, lastOffset: offset, lastMtime: mtime).save(db)
    }
}
