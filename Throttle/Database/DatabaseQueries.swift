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

    /// The `AND …` fragment, and its bindings, restricting a query to the model
    /// the weekly cap is scoped to.
    ///
    /// One definition, so the window's total and its reset time cannot disagree
    /// about which events are billable. They previously built the filter
    /// separately from the same raw display name, and both got it wrong the
    /// same way.
    static func scopedClause(
        _ match: ScopedCapModel.Match,
        column: String = "model"
    ) -> (sql: String, args: [any DatabaseValueConvertible]) {
        switch match {
        case .family(let tier):
            let family = ModelPricing.sqlFamilyPredicate(forBucket: tier.rawValue, column: column)
            // `.other` is unreachable via `ScopedCapModel.match(forDisplayName:)`.
            // Should a future caller build one, restricting to the documented
            // default beats counting *every* model against a per-model cap.
            let fallback = ModelPricing.sqlFamilyPredicate(
                forBucket: ModelTier.sonnet.rawValue, column: column)
            guard let predicate = family ?? fallback else { return ("", []) }
            return (" AND " + predicate, [])
        case .nameToken(let token):
            return (" AND lower(\(column)) LIKE ?", ["%" + token + "%"])
        }
    }

    /// Weighted token total for the model the scoped weekly cap belongs to.
    ///
    /// The scoped cap is not always Sonnet — on this account it was scoped to
    /// Fable — so the caller supplies the match rather than the query
    /// hardcoding a family.
    static func totalTokens(
        in db: Database,
        sinceTimestamp: Int64,
        scoped: ScopedCapModel.Match
    ) throws -> Int {
        let clause = scopedClause(scoped)
        var args: [any DatabaseValueConvertible] = [sinceTimestamp]
        args += clause.args
        let row = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(\(weightedTokenSumExpr)), 0) AS total
            FROM usage_events
            WHERE timestamp > ?\(clause.sql)
            """, arguments: StatementArguments(args))
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
        if let predicate = ModelPricing.sqlFamilyPredicate(forBucket: modelTier.rawValue) {
            sql += " AND " + predicate
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
        try FileState(
            path: path,
            lastOffset: offset,
            lastMtime: mtime,
            encodedProject: FileState.encodedProject(from: path),
            sessionId: FileState.sessionId(from: path)
        ).save(db)
    }
}
