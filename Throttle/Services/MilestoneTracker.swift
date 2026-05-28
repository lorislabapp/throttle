import Foundation
import SwiftUI

/// Tracks lifetime tokens saved by Throttle's optimizer and hooks, and
/// fires a "you saved a month of Pro" celebration the first time the
/// cumulative EUR value crosses each milestone. Persisted in
/// UserDefaults so the celebration doesn't re-fire across launches.
///
/// Why lifetime instead of weekly? A weekly counter resets every 7 days
/// and the milestones would constantly re-fire (or never fire if the
/// user is consistent). Lifetime accumulates each week's gains and
/// captures the long-term value of Throttle on the user's wallet.
@MainActor
@Observable
final class MilestoneTracker {
    static let shared = MilestoneTracker()

    /// Milestone ladder, ordered by EUR threshold. Each entry corresponds
    /// to "one month of <plan> at €X". The label is what we show in the
    /// celebration banner.
    struct Milestone: Identifiable, Sendable, Hashable {
        let id: String
        let thresholdEUR: Double
        let label: String
        /// Emoji shown next to the banner. Kept compact so the banner
        /// doesn't dominate the dropdown.
        let emoji: String
    }

    static let ladder: [Milestone] = [
        Milestone(id: "day_pro",    thresholdEUR:   0.65, label: String(localized: "1 day of Pro paid back"),     emoji: "🌱"),
        Milestone(id: "week_pro",   thresholdEUR:   4.50, label: String(localized: "1 week of Pro paid back"),    emoji: "🌿"),
        Milestone(id: "month_pro",  thresholdEUR:  18.00, label: String(localized: "1 month of Pro paid back"),   emoji: "🍀"),
        Milestone(id: "month_max5", thresholdEUR:  92.00, label: String(localized: "1 month of Max 5× paid back"), emoji: "🌳"),
        Milestone(id: "month_max20", thresholdEUR: 184.00, label: String(localized: "1 month of Max 20× paid back"), emoji: "🏆")
    ]

    /// Realistic blended €/M weighted-tokens rate. Based on typical Claude
    /// Code usage patterns (70-80% input, 20-30% output), using Sonnet 4.6
    /// pricing: €2.76/M input + €13.80/M output → ~€6/M blended average.
    /// This represents actual API costs rather than input-only rate.
    private let blendedRatePerM: Double = 6.00

    /// Lifetime weighted tokens saved across all weeks since install.
    /// Persisted across launches.
    private(set) var lifetimeTokens: Int {
        get { UserDefaults.standard.integer(forKey: "throttle.milestone.lifetimeTokens") }
        set { UserDefaults.standard.set(newValue, forKey: "throttle.milestone.lifetimeTokens") }
    }

    /// The last weekly-tokens snapshot we observed, so we can detect
    /// week rollovers and avoid double-counting within a week.
    private var lastWeeklySnapshot: Int {
        get { UserDefaults.standard.integer(forKey: "throttle.milestone.lastWeeklySnapshot") }
        set { UserDefaults.standard.set(newValue, forKey: "throttle.milestone.lastWeeklySnapshot") }
    }

    /// IDs of milestones already celebrated, so we never re-fire.
    private var firedMilestones: Set<String> {
        get {
            let arr = UserDefaults.standard.stringArray(forKey: "throttle.milestone.fired") ?? []
            return Set(arr)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: "throttle.milestone.fired")
        }
    }

    /// The milestone to celebrate right now (banner is showing). Cleared
    /// after the user dismisses or after 12 s of display.
    var pendingCelebration: Milestone?

    /// Computed lifetime EUR saved.
    var lifetimeEUR: Double {
        Double(lifetimeTokens) / 1_000_000 * blendedRatePerM
    }

    /// Call whenever `appState.savedTokensThisWeek` changes. Updates the
    /// lifetime counter and returns a milestone if a NEW one was crossed
    /// — caller should show a celebration banner for `pendingCelebration`.
    /// Idempotent: re-calling with the same weekly value is a no-op.
    @discardableResult
    func observeWeeklySnapshot(_ currentWeekly: Int) -> Milestone? {
        let prev = lastWeeklySnapshot
        if currentWeekly < prev {
            // Week rolled over (counter dropped). Lock in the previous
            // weekly value to lifetime.
            lifetimeTokens += prev
            lastWeeklySnapshot = currentWeekly
        } else if currentWeekly > prev {
            // Same week, counter went up. We don't add the delta to
            // lifetime *yet* — only at week rollover — but we DO let the
            // current weekly figure into the milestone check so the
            // user sees the celebration as soon as a threshold is
            // virtually crossed.
            lastWeeklySnapshot = currentWeekly
        } else {
            return nil
        }

        // Use lifetime + current weekly as the "live" figure for milestone
        // checks. This way the user gets the celebration the moment they
        // cross — even if the week hasn't rolled over yet.
        let liveTokens = lifetimeTokens + currentWeekly
        let liveEUR = Double(liveTokens) / 1_000_000 * blendedRatePerM

        // Find the highest unfired milestone the user has crossed.
        let crossed = Self.ladder
            .filter { $0.thresholdEUR <= liveEUR && !firedMilestones.contains($0.id) }
            .max(by: { $0.thresholdEUR < $1.thresholdEUR })

        if let crossed {
            // Mark all milestones at-or-below this one as fired (we don't
            // want to retro-fire smaller ones — the user just earned the
            // bigger milestone).
            var fired = firedMilestones
            for m in Self.ladder where m.thresholdEUR <= crossed.thresholdEUR {
                fired.insert(m.id)
            }
            firedMilestones = fired
            pendingCelebration = crossed
            return crossed
        }

        return nil
    }

    /// Dismiss the active celebration banner.
    func dismissCelebration() {
        pendingCelebration = nil
    }

    /// Reset everything (debug + Privacy "Clear local data" path).
    func reset() {
        lifetimeTokens = 0
        lastWeeklySnapshot = 0
        firedMilestones = []
        pendingCelebration = nil
    }
}
