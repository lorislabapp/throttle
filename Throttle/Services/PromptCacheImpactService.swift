import Foundation
import GRDB

/// Best-effort cost of rebuilding the latest observed prompt context after an
/// operation that changes Claude Code's prompt-cache key (model / effort / fast
/// mode) or restarts the process after hibernation.
///
/// This deliberately uses the latest request's input footprint, not the
/// session's cumulative token total. Claude reports the already-cached prefix as
/// `cache_read`, newly-cached input as `cache_create`, and uncached input as
/// `input_tokens`; together they approximate the context that a cold request
/// would have to prefill again.
struct PromptCacheImpact: Sendable, Equatable {
    let contextTokens: Int
    let model: String
    /// Approximate price of a cold cache write for the full observed context.
    let rebuildEUR: Double
    /// Increment versus reading the same context from a warm cache (1.25x - 0.10x).
    let extraEURVersusWarm: Double

    var shouldWarn: Bool { contextTokens >= 30_000 }
}

enum PromptCacheImpactService {
    private static let usdToEUR = 0.93

    static func latest(in db: Database, sessionId: String) throws -> PromptCacheImpact? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT model, input_tokens, cache_create, cache_read
            FROM usage_events
            WHERE session_id = ?
            ORDER BY timestamp DESC, id DESC
            LIMIT 1
            """, arguments: [sessionId]) else { return nil }

        let model: String = row["model"] ?? ""
        let input: Int = row["input_tokens"] ?? 0
        let create: Int = row["cache_create"] ?? 0
        let read: Int = row["cache_read"] ?? 0
        return estimate(contextTokens: input + create + read, model: model)
    }

    static func estimate(contextTokens: Int, model: String) -> PromptCacheImpact? {
        guard contextTokens > 0 else { return nil }
        let rate = inputRate(model)
        let units = Double(contextTokens) / 1_000_000.0
        return PromptCacheImpact(
            contextTokens: contextTokens,
            model: model,
            rebuildEUR: units * rate * 1.25 * usdToEUR,
            extraEURVersusWarm: units * rate * 1.15 * usdToEUR
        )
    }

    /// Re-price the same context for a target model before `/model` is sent.
    static func repriced(_ impact: PromptCacheImpact, for model: String) -> PromptCacheImpact {
        estimate(contextTokens: impact.contextTokens, model: model) ?? impact
    }

    private static func inputRate(_ model: String) -> Double {
        let value = model.lowercased()
        if value.contains("fable") || value.contains("mythos") { return 10 }
        if value.contains("opus") { return 5 }
        if value.contains("haiku") { return 1 }
        return 3 // Sonnet and unknown models: conservative product default.
    }
}
