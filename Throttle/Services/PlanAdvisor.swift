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

    // Official Anthropic API rates (USD × 0.92), refreshed 2026-06-11.
    static let fable5   = ModelRate(inputPerM:  9.20, outputPerM: 46.00)   // $10 / $50  (Fable 5 / Mythos 5)
    static let opus47   = ModelRate(inputPerM:  4.60, outputPerM: 23.00)   // $5  / $25  (Opus 4.5–4.8)
    static let sonnet46 = ModelRate(inputPerM:  2.76, outputPerM: 13.80)   // $3  / $15  (Sonnet 4.5/4.6)
    static let haiku45  = ModelRate(inputPerM:  0.92, outputPerM:  4.60)   // $1  / $5   (Haiku 4.5)

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
        Plan(id: "free",    label: "Free",       monthlyEUR:   0.0, weeklyTokenCapacity:  10_000_000),
        Plan(id: "pro",     label: "Pro $20",    monthlyEUR:  18.40, weeklyTokenCapacity:  50_000_000),
        Plan(id: "max5x",   label: "Max 5×",     monthlyEUR:  92.00, weeklyTokenCapacity: 250_000_000),
        Plan(id: "max20x",  label: "Max 20×",    monthlyEUR: 184.00, weeklyTokenCapacity: 1_000_000_000)
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
    /// - opusFraction: 0…1 share of usage on Opus models. Defaults to
    ///   0.30 if unknown.
    /// - currentPlanID: optional id of the plan the user is on today
    ///   (free / pro / max5x / max20x).
    /// - dailyVarianceCoeff: 0…2 — coefficient of variation of daily
    ///   usage over the last 7d. >0.6 means spiky usage where Pro +
    ///   credits could beat a higher flat tier.
    static func recommend(
        weeklyWeightedTokens: Int,
        opusFraction: Double = 0.30,
        currentPlanID: String? = nil,
        dailyVarianceCoeff: Double = 0.0
    ) -> Verdict {
        // Project to monthly (4.33 weeks/month average).
        let monthlyTokens = Double(weeklyWeightedTokens) * 4.33

        // API equivalent EUR/mo. Mix Opus + Sonnet by the user's split.
        let opusFraction = max(0, min(1, opusFraction))
        let apiPerM = opusFraction * opus47.weightedPerM
                    + (1 - opusFraction) * sonnet46.weightedPerM
        let apiEquivalentMonthlyEUR = monthlyTokens / 1_000_000 * apiPerM

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
