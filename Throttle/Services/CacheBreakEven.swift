import Foundation

/// When does trimming a transcript actually pay for itself?
///
/// Trimming rewrites the JSONL, so the next turn cannot reuse the provider's cached
/// prefix: that turn is billed at the cache-WRITE rate (1.25× input) instead of the
/// cache-READ rate (0.10× input). In exchange, every turn after it reads a prefix
/// that is `trimmable` tokens lighter. Whether that trade is worth taking depends
/// entirely on whether the cache was still warm when you trimmed.
///
/// - Cache already cold (nothing touched the session inside the TTL): the next turn
///   was going to pay a full write anyway. Trimming makes that write *smaller*, so
///   it pays from the very first turn. This is the common case for the past-session
///   trimmer, and saying "pays back after 12 turns" there would be a lie.
/// - Cache still warm: there is a real one-off penalty, and it takes
///   `n* = ⌈penalty / savings⌉ + 1` turns of lighter reads to earn it back.
///
/// Rates are multipliers on the model's input price, so the verdict is
/// model-independent and no EUR figure has to be invented here.
enum CacheBreakEven {
    /// Anthropic bills a cache write at 1.25× the input rate, a cache read at 0.10×.
    static let writeMultiplier = 1.25
    static let readMultiplier = 0.10

    /// Claude Code sessions run on the 1-hour cache TTL. Past that, the prefix is
    /// gone and resuming re-writes it whether or not you trimmed.
    static let cacheTTL: TimeInterval = 3600

    struct Verdict: Sendable, Equatable {
        /// The prefix was still cached when measured — trimming forfeits it.
        let cacheWasWarm: Bool
        /// Turns of lighter reads needed before the trim is net-positive.
        /// 1 = it pays from the next turn.
        let turns: Int

        /// Nothing to weigh up — take it.
        var paysImmediately: Bool { turns <= 1 }
    }

    /// - Parameters:
    ///   - prefixTokens: size of the transcript that gets re-sent each turn.
    ///   - trimmableTokens: what the trim would remove from that prefix.
    ///   - lastActivity: when the session last produced a turn.
    ///   - now: injected for tests.
    /// - Returns: nil when there is nothing to trim, or when the trim would remove
    ///   the whole prefix (no residual reads left to amortise anything against —
    ///   a break-even number there would be meaningless rather than merely uncertain).
    static func evaluate(
        prefixTokens: Int,
        trimmableTokens: Int,
        lastActivity: Date,
        now: Date = Date()
    ) -> Verdict? {
        guard trimmableTokens > 0, prefixTokens > 0 else { return nil }
        let trimmable = min(trimmableTokens, prefixTokens)
        let remaining = prefixTokens - trimmable
        guard remaining > 0 else { return nil }

        let warm = now.timeIntervalSince(lastActivity) < cacheTTL
        guard warm else { return Verdict(cacheWasWarm: false, turns: 1) }

        // Extra cost of the trimming turn: rewrite the smaller prefix instead of
        // reading the whole one.
        let penalty = Double(remaining) * writeMultiplier - Double(prefixTokens) * readMultiplier
        guard penalty > 0 else { return Verdict(cacheWasWarm: true, turns: 1) }

        // Earned back on every later turn: the trimmed tokens are no longer read.
        let savingsPerTurn = Double(trimmable) * readMultiplier
        guard savingsPerTurn > 0 else { return nil }

        return Verdict(cacheWasWarm: true, turns: Int(ceil(penalty / savingsPerTurn)) + 1)
    }
}
