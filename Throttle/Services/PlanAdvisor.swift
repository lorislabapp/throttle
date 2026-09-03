import Foundation

/// Plan & extra-credit advisor. Given the user's actual weighted-token
/// usage and model split (Opus / Sonnet split as seen in the Stats),
/// figures out which Anthropic offering is the best fit and whether
/// flat subscription or pay-as-you-go-with-credits would save them money.
///
/// Prices are 2026-01 Anthropic public rates expressed in EUR using a
/// stable 0.92 USD→EUR conversion. The advisor is intentionally
/// conservative — it underestimates cache savings (real users hit more
/// cache than the model split alone reveals), so its recommendations
/// err on the side of "yes, a flat sub still pays off." We surface the
/// raw API equivalent so the user can sanity-check the math.
enum PlanAdvisor {

    /// Anthropic API per-million-token pricing in EUR. Cached reads bill
    /// at ~10% of input, cache writes at ~125%. Throttle's "weighted
    /// tokens" metric already folds cache_read into a 1/10 contribution,
    /// so we charge weighted tokens at the input rate for a clean
    /// linear projection.
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

    /// Derived from `ModelPricing`, never typed out again.
    ///
    /// These were four hardcoded constants converted at **0.92** while
    /// `ModelPricing.usdToEur` is 0.93 — two euro rates in one app — and the
    /// names were generation-locked (`opus47`, `sonnet46`), the same
    /// label-names-the-wrong-model class fixed elsewhere today. `ModelPricing`
    /// was created with the header "one table, one conversion"; this is the copy
    /// that survived it.
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
    /// Opus-vs-Sonnet fraction, which charged the Sonnet rate to every family
    /// that was neither — Fable most of all, at 3.33× under its real rate
    /// (€20.46/M priced as €6.14/M), on an account where Fable is the
    /// second-largest tier. This figure is the "vs API" number the plan
    /// decision is made on, so it was the one number worth getting right.
    ///
    /// ## Assumptions, written here because this number is acted on
    ///
    /// * **A family with no published rate** (`ModelTier.other`, i.e. a model
    ///   id Throttle could not classify) is priced through
    ///   `ModelPricing.rate(forBucket:)`, whose `unknown` fallback is the
    ///   Sonnet rate. That is the app-wide convention and is deliberately not
    ///   re-decided here. **It is reachable**, and the error is one-directional:
    ///   an unclassified id is usually a *new* frontier model, which bills
    ///   above Sonnet, so this **understates** the API figure and therefore
    ///   errs *against* the subscription — it makes paying per token look
    ///   cheaper than it is. Nothing silently rounds up to flatter the plan.
    /// * **An empty or all-zero mix** means the caller has no split to offer.
    ///   It falls back to the long-standing 30% Opus / 70% Sonnet guess, so a
    ///   caller without a split gets exactly the number it always got. A mix
    ///   that *is* supplied is used whole; there is no partial blending.
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

    /// One family's weighted API rate, EUR per million.
    ///
    /// The single place a `ModelTier` becomes money. `.other` resolves through
    /// `ModelPricing`'s `unknown` fallback (the Sonnet rate) — see
    /// `apiRateEURPerM(mix:)` for what that assumes and which way it errs.
    /// Callers that spelled their own five-case switch got `.other` right by
    /// copying it, which is not the same as deciding it.
    static func weightedEURPerM(for tier: ModelTier) -> Double {
        rate(tier.rawValue).weightedPerM
    }

    /// Subscription tiers, monthly EUR (USD × 0.92). Anthropic's published
    /// caps are per 5-hour window with a weekly ceiling. We translate to
    /// "weighted tokens / week" using publicly observed numbers.
    struct Plan: Sendable, Hashable {
        let id: String
        let label: String
        let monthlyEUR: Double
        /// Approximate weekly weighted-token capacity. Empirical, not
        /// official — Anthropic doesn't publish a token cap, only a
        /// message cap and 5h window.
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
    }

    /// Compute the verdict.
    /// - weeklyWeightedTokens: from `costForProject(...)` — the same
    ///   number Throttle already shows in the Stats card.
    /// - mix: weighted tokens per family, straight from the model split.
    ///   Empty means "no split available" — see `apiRateEURPerM(mix:)`.
    /// - currentPlanID: optional id of the plan the user is on today
    ///   (free / pro / max5x / max20x).
    /// - dailyVarianceCoeff: 0…2 — coefficient of variation of daily
    ///   usage over the last 7d. >0.6 means spiky usage where Pro +
    ///   credits could beat a higher flat tier.
    static func recommend(
        weeklyWeightedTokens: Int,
        mix: [ModelTier: Int] = [:],
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
            extraCreditHint: extra
        )
    }

    // MARK: - Per-plan fit (Stats "statement" table)

    /// A plan's consequence given the user's weekly burn. Honest by design:
    /// no specific throttle-day forecast — the caps are empirical, so a
    /// confident "throttles Thursday" would be exactly the over-claim
    /// Throttle refuses. Words only.
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
