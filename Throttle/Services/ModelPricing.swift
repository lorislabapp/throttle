import Foundation

/// The one place Throttle states what a token costs.
///
/// ## Why it exists
///
/// These rates were written out six times — five copies in `StatsDataService`,
/// one in `CockpitQueries` — plus the EUR conversion in five files. On
/// 2026-08-22 one of those copies still carried Claude 3 Opus prices ($15/$75)
/// and applied them to Opus 4.8 and Opus 5, which bill at $5/$25, while the
/// copies beside it already had the right numbers. Thirty days of cost came out
/// **2.3× high**. In the same audit, Fable matched no branch at all and fell
/// through to the Sonnet default while billing $10/$50, so it was understated
/// threefold.
///
/// Neither was a hard bug to write. Both were impossible to *notice*, because
/// no single place claimed to be authoritative and each copy looked right on its
/// own. The same evening, a label fixed in the cockpit stayed wrong in the menu
/// bar for exactly the same reason. So: one table, one conversion, one SQL
/// fragment — and when a price changes, one edit.
enum ModelPricing {

    /// Official developer-API list prices, USD per million tokens.
    /// Refreshed 2026-06-11.
    struct Rate: Sendable, Equatable {
        let input: Double
        let output: Double
    }

    static let fable = Rate(input: 10, output: 50)
    static let opus = Rate(input: 5, output: 25)
    static let sonnet = Rate(input: 3, output: 15)
    static let haiku = Rate(input: 1, output: 5)

    /// A model we do not recognise is priced as Sonnet — the middle of the
    /// range, and the assumption already made everywhere else.
    static let unknown = sonnet

    /// Cache multipliers on the INPUT rate. A write costs 1.25×, a read 0.10×.
    static let cacheWriteMultiplier = 1.25
    static let cacheReadMultiplier = 0.10

    /// Flat conversion, so cost stays computable offline.
    static let usdToEur = 0.93

    /// Bucket names as produced by `sqlBucketExpr`.
    static func rate(forBucket bucket: String) -> Rate {
        switch bucket {
        case "fable":  return fable
        case "opus":   return opus
        case "sonnet": return sonnet
        case "haiku":  return haiku
        default:       return unknown
        }
    }

    static func rate(forModel model: String) -> Rate {
        rate(forBucket: bucket(forModel: model))
    }

    static func bucket(forModel model: String) -> String {
        let lower = model.lowercased()
        if lower.contains("fable") || lower.contains("mythos") { return "fable" }
        if lower.contains("opus") { return "opus" }
        if lower.contains("sonnet") { return "sonnet" }
        if lower.contains("haiku") { return "haiku" }
        return "other"
    }

    /// EUR for one bucket's token counts. The single arithmetic definition of
    /// cost; every caller goes through it.
    static func eur(bucket: String, input: Int, output: Int, cacheCreate: Int, cacheRead: Int) -> Double {
        let rate = rate(forBucket: bucket)
        let perMillion = 1_000_000.0
        var usd = Double(input) / perMillion * rate.input
        usd += Double(output) / perMillion * rate.output
        usd += Double(cacheCreate) / perMillion * rate.input * cacheWriteMultiplier
        usd += Double(cacheRead) / perMillion * rate.input * cacheReadMultiplier
        return usd * usdToEur
    }

    /// How much more a model costs per token than Sonnet, on the INPUT rate —
    /// the ratio the model-split chart weights by. Derived, never typed out: the
    /// hardcoded copy carried `opus 5.0 / haiku 0.27` (Claude 3 ratios) and had
    /// no Fable branch at all.
    static func priceMultiplier(forBucket bucket: String) -> Double {
        (rate(forBucket: bucket).input / sonnet.input * 100).rounded() / 100
    }

    // MARK: - SQL

    /// `CASE … END` mapping `model` to a bucket name. Takes the column
    /// expression so it works with or without a table alias.
    static func sqlBucketExpr(_ column: String = "model") -> String {
        """
        CASE
            WHEN lower(\(column)) LIKE '%fable%' OR lower(\(column)) LIKE '%mythos%' THEN 'fable'
            WHEN lower(\(column)) LIKE '%opus%'   THEN 'opus'
            WHEN lower(\(column)) LIKE '%sonnet%' THEN 'sonnet'
            WHEN lower(\(column)) LIKE '%haiku%'  THEN 'haiku'
            ELSE 'other'
        END
        """
    }

    /// `CASE … END` yielding the per-token price multiplier relative to Sonnet.
    static func sqlPriceMultiplierExpr(_ column: String = "model") -> String {
        """
        (CASE
            WHEN lower(\(column)) LIKE '%fable%' OR lower(\(column)) LIKE '%mythos%'
                THEN \(priceMultiplier(forBucket: "fable"))
            WHEN lower(\(column)) LIKE '%opus%'  THEN \(priceMultiplier(forBucket: "opus"))
            WHEN lower(\(column)) LIKE '%haiku%' THEN \(priceMultiplier(forBucket: "haiku"))
            ELSE 1.0
         END)
        """
    }

    /// Per-row EUR expression, for the cases that must SUM inside a correlated
    /// subquery rather than group in Swift. Generated from the same table above,
    /// so it cannot drift from `eur(bucket:…)`.
    static func sqlRowEurExpr(_ column: String = "model") -> String {
        func branch(_ rate: Rate) -> String {
            let write = rate.input * cacheWriteMultiplier
            let read = rate.input * cacheReadMultiplier
            return "input_tokens/1e6*\(rate.input) + output_tokens/1e6*\(rate.output)"
                + " + cache_create/1e6*\(write) + cache_read/1e6*\(read)"
        }
        return """
        (CASE
           WHEN lower(\(column)) LIKE '%fable%' OR lower(\(column)) LIKE '%mythos%' THEN \(branch(fable))
           WHEN lower(\(column)) LIKE '%opus%'   THEN \(branch(opus))
           WHEN lower(\(column)) LIKE '%sonnet%' THEN \(branch(sonnet))
           WHEN lower(\(column)) LIKE '%haiku%'  THEN \(branch(haiku))
           ELSE \(branch(unknown))
         END) * \(usdToEur)
        """
    }
}
