import Foundation

/// Plan & extra-credit advisor. Given the user's weighted-token usage and model
/// split, figures out which Anthropic offering fits and whether a flat
/// subscription or pay-as-you-go-with-credits is cheaper. Prices come from
/// `ModelPricing` at its `usdToEur` (0.93); this header used to name 0.92 and a
/// second rate table, and both are gone.
///
/// ## Whether the API equivalent is an upper bound — conditionally
///
/// It used to say, flatly, that the advisor errs toward "yes, a flat sub still
/// pays off". Two things can make that false, and neither was checked:
/// *composition* (output is under-charged — see `isUpperBound(_:)`) and
/// *unrated families* (priced at Sonnet while a new family bills above it, as
/// Fable did at 3.33× when it was this account's second-largest tier).
///
/// So the claim is carried in the data, not in prose: `Verdict.apiBasis` says
/// which case a figure is in, and the badge must not claim more. See `APIBasis`.
enum PlanAdvisor {

    /// Anthropic API per-million-token pricing in EUR.
    struct ModelRate {
        let inputPerM: Double      // EUR / 1M tokens
        let outputPerM: Double     // EUR / 1M tokens
        /// Weighted-token-equivalent rate. Since "weighted tokens" =
        /// input + output + cache_create + (cache_read/10), we need a
        /// blended rate. Typical usage is ~70% input / 30% output.
        var weightedPerM: Double {
            0.70 * inputPerM + 0.30 * outputPerM
        }
    }

    /// Derived from `ModelPricing`, never typed out again. These were four
    /// constants converted at 0.92 while `ModelPricing.usdToEur` is 0.93, with
    /// generation-locked names (`opus47`, `sonnet46`).
    private static func rate(_ bucket: String) -> ModelRate {
        let base = ModelPricing.rate(forBucket: bucket)
        return ModelRate(inputPerM: base.input * ModelPricing.usdToEur,
                         outputPerM: base.output * ModelPricing.usdToEur)
    }

    static var fable: ModelRate { rate("fable") }
    static var opus: ModelRate { rate("opus") }
    static var sonnet: ModelRate { rate("sonnet") }
    static var haiku: ModelRate { rate("haiku") }

    /// Blended API rate, EUR per million weighted tokens, for an observed mix.
    ///
    /// Every family is priced at *its own* rate. This used to be a single
    /// Opus-vs-Sonnet fraction, charging the Sonnet rate to every family that
    /// was neither — Fable most of all, at 3.33× under its real rate (€20.46/M
    /// priced as €6.14/M) while it was this account's second-largest tier.
    ///
    /// ## Assumptions, written here because this number is acted on
    ///
    /// * **A family with no published rate** (`ModelTier.other`) takes
    ///   `ModelPricing`'s `unknown` fallback, the Sonnet rate — the app-wide
    ///   convention, not re-decided here. **It is reachable**, and errs one way:
    ///   an unclassified id is usually a *new*, dearer model, so this
    ///   **understates** the figure and errs *against* the subscription.
    /// * **An empty or all-zero mix** falls back to the 30/70 Opus/Sonnet guess.
    /// * Negative counts are treated as zero rather than subtracting.
    static func apiRateEURPerM(mix: [ModelTier: Int]) -> Double {
        let total = mix.values.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else {
            return 0.30 * opus.weightedPerM + 0.70 * sonnet.weightedPerM
        }
        return mix.reduce(0.0) { blended, entry in
            let tokens = max(0, entry.value)
            guard tokens > 0 else { return blended }
            return blended + Double(tokens) / Double(total) * weightedEURPerM(for: entry.key)
        }
    }

    /// What the "API equivalent" figure rests on. The badge beside it must not
    /// claim more than this — the cases are not interchangeable, and a guess
    /// wearing the same label as a measurement is the failure this area keeps
    /// repeating.
    enum APIBasis: String, Sendable, Equatable {
        /// Measured, fully rated, inequality holds. A genuine upper bound.
        case boundedByMeasuredMix
        /// A material share of tokens Throttle could not classify, priced at
        /// the Sonnet fallback while a new family bills above it. Not a bound.
        case measuredMixWithUnratedFamily
        /// Fully rated, but output-heavy enough that the under-charge on
        /// output beats the over-charge on input and cache. Not a bound.
        case outputHeavyNotABound
        /// The composition could not be read, so the inequality could not be
        /// evaluated. Fails closed. Exists because `.empty` meant both "no
        /// tokens" and "we do not know", so a failed query rendered the
        /// strongest claim available.
        case compositionUnavailable
        /// No split available: the 30/70 guess. Not measured, not a bound.
        case assumedMix
    }

    /// The four raw token columns, per family — the bound is a *rate-weighted*
    /// comparison and summing across families discards the rates.
    struct TokenComposition: Sendable, Equatable {
        let input: Int
        let output: Int
        let cacheCreate: Int
        let cacheRead: Int
    }

    /// Whether the weighted-token figure really is an upper bound on API cost.
    ///
    /// Evaluated, never assumed. `weightedPerM = 0.70·input + 0.30·output` and
    /// output bills at 5× input, so a weighted unit costs 2.2× that family's
    /// input rate. Per *real* token, in units of that rate: input 2.20 vs 1.00,
    /// cache_create 2.20 vs 1.25, cache_read 0.22 vs 0.10 — all over — but
    /// output 2.20 vs 5.00, under. Within one family it bounds cost while
    /// `1.2·input + 0.95·cache_create + 0.12·cache_read ≥ 2.8·output`.
    ///
    /// The multiples are family-independent; the *rates they multiply* are not,
    /// which is where an earlier version was wrong. Summing the columns across
    /// families and testing once discards the rates: 10 000 Sonnet input against
    /// 3 000 Fable output passes on raw sums (12 000 ≥ 8 400) and fails once
    /// each side carries its rate (3 × 12 000 vs 10 × 8 400). So each side is
    /// scaled by its family's input rate before summing.
    ///
    /// Holds for cache-heavy Claude Code, not for a low-cache generation-heavy
    /// week: 2 000 in / 8 000 out with no cache is charged 22 000 input-units
    /// against a true 42 000.
    static func isUpperBound(_ byFamily: [ModelTier: TokenComposition]) -> Bool {
        var over = 0.0
        var under = 0.0
        for (tier, part) in byFamily {
            let rate = ModelPricing.rate(forBucket: tier.rawValue).input
            over += rate * (1.20 * Double(part.input)
                            + 0.95 * Double(part.cacheCreate)
                            + 0.12 * Double(part.cacheRead))
            under += rate * 2.80 * Double(part.output)
        }
        return over >= under
    }

    /// Unrated share below which the rate table's gap cannot matter. Without
    /// one, a single stray unclassified row permanently retires the badge. At
    /// 1%, even if every unrated token were Fable (3.33× Sonnet), the figure
    /// moves under 2.4% — well inside the composition overstatement.
    static let unratedShareTolerance = 0.01

    /// Which case a figure falls into, decided beside the figure itself.
    ///
    /// Unrated is reported ahead of output-heavy when both apply: both mean
    /// "not a bound", but an unrated family is a gap Throttle can close, while
    /// an output-heavy week is a property of the user's own usage. A `nil`
    /// composition fails closed — see `APIBasis.compositionUnavailable`.
    static func apiBasis(
        for mix: [ModelTier: Int],
        composition: [ModelTier: TokenComposition]?
    ) -> APIBasis {
        let total = mix.values.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else { return .assumedMix }
        let unrated = max(0, mix[.other] ?? 0)
        // LOAD-BEARING ORDER. `.other` is priced at the Sonnet fallback, which
        // is the *unsafe* direction — a new family bills above Sonnet — and the
        // inequality below knows nothing about that, because it compares
        // published rates and an unrated family has none. This check is the only
        // thing keeping an unrated mix out of the bound. Do not move it after.
        if Double(unrated) / Double(total) > unratedShareTolerance {
            return .measuredMixWithUnratedFamily
        }
        // An empty dictionary is the second value that means both "no tokens"
        // and "nothing to check": `isUpperBound([:])` is `0 >= 0`, i.e. the
        // strongest claim from no evidence. Deleting `TokenComposition.empty`
        // closed that one caller away; this closes it here.
        guard let composition, !composition.isEmpty else { return .compositionUnavailable }
        return isUpperBound(composition) ? .boundedByMeasuredMix : .outputHeavyNotABound
    }

    /// Weighted tokens per family from a model split.
    static func mix(from slices: [StatsDataService.ModelSlice]) -> [ModelTier: Int] {
        Dictionary(slices.map { ($0.tier, $0.weightedTokens) }, uniquingKeysWith: +)
    }

    /// The Stats advisor's loaded inputs, and every derivation from them.
    ///
    /// The view held `modelSlices` as its own `@State` and handed them over at
    /// the call site, so that line could regress with the suite green — first as
    /// `mix: [:]`, then, once the mix moved behind a builder, as `slices: []`.
    /// The argument kept moving one position left. There is now no argument to
    /// pass: the loaded state and the verdict are one value, tested as one.
    struct StatsInput: Equatable, Sendable {
        var slices: [StatsDataService.ModelSlice] = []
        /// `nil` means the query failed, not that there were no tokens.
        var composition: [ModelTier: TokenComposition]?

        var totalWeightedTokens: Int { slices.reduce(0) { $0 + $1.weightedTokens } }

        var hasModelData: Bool {
            !(slices.isEmpty || slices.allSatisfy { $0.weightedTokens == 0 })
        }

        func weeklyTokens(range: StatsDataService.Range) -> Int {
            switch range {
            case .last24h: return totalWeightedTokens * 7
            case .last7d:  return totalWeightedTokens
            case .last30d: return totalWeightedTokens * 7 / 30
            case .all:     return 0
            }
        }

        func verdict(
            range: StatsDataService.Range,
            currentPlanID: String?
        ) -> Verdict? {
            let weekly = weeklyTokens(range: range)
            guard weekly > 0, range != .all else { return nil }
            return recommend(
                weeklyWeightedTokens: weekly,
                mix: mix(from: slices),
                composition: composition,
                currentPlanID: currentPlanID
            )
        }
    }

    /// One family's weighted API rate, EUR per million.
    ///
    /// The single place a `ModelTier` becomes money. `.other` resolves through
    /// `ModelPricing`'s `unknown` fallback (the Sonnet rate) — see
    /// `apiRateEURPerM(mix:)` for what that assumes and which way it errs.
    static func weightedEURPerM(for tier: ModelTier) -> Double {
        rate(tier.rawValue).weightedPerM
    }

    /// Subscription tiers, monthly EUR. Anthropic publishes a message cap and a
    /// 5-hour window, not a token cap; these are publicly observed numbers.
    struct Plan: Sendable, Hashable {
        let id: String
        let label: String
        let monthlyEUR: Double
        /// Approximate weekly weighted-token capacity. Empirical, not official.
        let weeklyTokenCapacity: Int
    }

    static let plans: [Plan] = [
        Plan(id: "free", label: "Free", monthlyEUR: 0.0, weeklyTokenCapacity: 10_000_000),
        Plan(id: "pro", label: "Pro $20", monthlyEUR: 18.40, weeklyTokenCapacity: 50_000_000),
        Plan(id: "max5x", label: "Max 5×", monthlyEUR: 92.00, weeklyTokenCapacity: 250_000_000),
        Plan(id: "max20x", label: "Max 20×", monthlyEUR: 184.00, weeklyTokenCapacity: 1_000_000_000)
    ]

    struct Verdict: Sendable {
        /// The cheapest plan that comfortably covers the observed usage,
        /// or the closest one if even Max 20× is below need (then API
        /// pay-as-you-go is cheaper than flat).
        let bestPlanID: String
        /// Headline EUR/mo for the best fit.
        let bestPlanMonthlyEUR: Double
        /// What the same usage would cost at API rates per month.
        let apiEquivalentMonthlyEUR: Double
        /// What the user pays today at their current plan (or 0 if free).
        let currentMonthlyEUR: Double
        /// Positive = currentPlan overpays vs bestPlan. Negative = upgrade
        /// recommended (and the absolute value is the under-coverage
        /// burn at API rates).
        let monthlyDeltaEUR: Double
        /// One-line plain-English reason. Localized via String(localized:).
        let reasoning: String
        /// Optional hint about extra-credit / Console pay-as-you-go.
        let extraCreditHint: String?
        /// What `apiEquivalentMonthlyEUR` rests on. Read it before labelling
        /// that number anything.
        let apiBasis: APIBasis
    }

    /// Compute the verdict.
    /// - weeklyWeightedTokens: the number the Stats card already shows.
    /// - mix: weighted tokens per family, from the model split. Empty means
    ///   "no split available" — see `apiRateEURPerM(mix:)`.
    /// - currentPlanID: plan the user is on today (free/pro/max5x/max20x).
    /// - dailyVarianceCoeff: 0…2, coefficient of variation of daily usage over
    ///   7d. >0.6 is spiky, where Pro + credits can beat a higher flat tier.
    static func recommend(
        weeklyWeightedTokens: Int,
        mix: [ModelTier: Int],
        composition: [ModelTier: TokenComposition]?,
        currentPlanID: String? = nil,
        dailyVarianceCoeff: Double = 0.0
    ) -> Verdict {
        // Project to monthly (4.33 weeks/month average).
        let monthlyTokens = Double(weeklyWeightedTokens) * 4.33
        let apiEquivalentMonthlyEUR = monthlyTokens / 1_000_000 * apiRateEURPerM(mix: mix)

        // Find the cheapest plan that covers the weekly capacity.
        let weeklyTokens = max(0, weeklyWeightedTokens)
        let bestPlan: Plan
        if let fit = plans.first(where: { weeklyTokens <= $0.weeklyTokenCapacity }) {
            bestPlan = fit
        } else {
            bestPlan = plans.last! // Max 20× is the ceiling
        }

        let currentPlan = plans.first { $0.id == currentPlanID }
        let currentMonthlyEUR = currentPlan?.monthlyEUR ?? 0

        // Delta vs best: +overpay (currentEUR > bestEUR), −underpay (current < best).
        // For underpay we expose the absolute over-API burn the user would
        // hit if they stayed (the "burn rate" is what they'd actually pay
        // by buying credits).
        let monthlyDeltaEUR: Double
        if let cur = currentPlan {
            monthlyDeltaEUR = cur.monthlyEUR - bestPlan.monthlyEUR
        } else {
            monthlyDeltaEUR = apiEquivalentMonthlyEUR - bestPlan.monthlyEUR
        }

        // Build the verdict text.
        let reasoning: String
        let extra: String?
        if let cur = currentPlan, cur.id == bestPlan.id {
            reasoning = String(localized: "Your current plan is the best fit for this usage profile.")
            extra = nil
        } else if currentPlan == nil {
            reasoning = String(localized: "\(bestPlan.label) covers your weekly token capacity.")
            extra = nil
        } else if monthlyDeltaEUR > 0 {
            reasoning = String(format: String(localized: "You could save €%.0f/mo by switching to %@."),
                               monthlyDeltaEUR, bestPlan.label)
            // Spiky usage hint: Pro + Console credits at -30% can beat
            // a higher flat tier when usage spikes only a few days/month.
            if dailyVarianceCoeff > 0.6 && bestPlan.id == "max5x" {
                extra = String(localized: "If your spikes are 1–2 days/month, Pro + Anthropic Console credits at up to −30% could beat Max 5× too.")
            } else {
                extra = nil
            }
        } else {
            reasoning = String(format: String(localized: "%@ would cover this — currently underpaying ≈€%.0f/mo at API rates."),
                               bestPlan.label, abs(monthlyDeltaEUR))
            extra = String(localized: "Or stay on your plan and add Console credits at up to −30%.")
        }

        return Verdict(
            bestPlanID: bestPlan.id,
            bestPlanMonthlyEUR: bestPlan.monthlyEUR,
            apiEquivalentMonthlyEUR: apiEquivalentMonthlyEUR,
            currentMonthlyEUR: currentMonthlyEUR,
            monthlyDeltaEUR: monthlyDeltaEUR,
            reasoning: reasoning,
            extraCreditHint: extra,
            apiBasis: apiBasis(for: mix, composition: composition)
        )
    }

    // MARK: - Per-plan fit (Stats "statement" table)

    /// A plan's consequence given the weekly burn. No throttle-day forecast:
    /// the caps are empirical, so "throttles Thursday" would be an over-claim.
    enum Fit: Sendable {
        case throttled, tight, comfortable, overProvisioned

        var label: String {
            switch self {
            case .throttled:       return String(localized: "throttled")
            case .tight:           return String(localized: "tight")
            case .comfortable:     return String(localized: "comfortable")
            case .overProvisioned: return String(localized: "over-provisioned")
            }
        }
    }

    struct LadderRow: Sendable, Identifiable {
        let id: String
        let label: String
        let monthlyEUR: Double
        let fit: Fit
        let isCurrent: Bool
        let isBest: Bool
    }

    /// Map weekly weighted-token burn against a plan's capacity to a fit word.
    static func fit(weeklyTokens: Int, planCapacity: Int) -> Fit {
        guard planCapacity > 0 else { return .throttled }
        let ratio = Double(max(0, weeklyTokens)) / Double(planCapacity)
        switch ratio {
        case ..<0.25: return .overProvisioned
        case ..<0.85: return .comfortable
        case ..<1.0:  return .tight
        default:      return .throttled
        }
    }

    /// The full ladder with a per-plan fit, the current plan flagged, and the
    /// best plan flagged — the data the Stats statement table renders.
    static func ladder(weeklyTokens: Int, currentPlanID: String?, bestPlanID: String) -> [LadderRow] {
        plans.map { p in
            LadderRow(
                id: p.id,
                label: p.label,
                monthlyEUR: p.monthlyEUR,
                fit: fit(weeklyTokens: weeklyTokens, planCapacity: p.weeklyTokenCapacity),
                isCurrent: p.id == currentPlanID,
                isBest: p.id == bestPlanID
            )
        }
    }
}
