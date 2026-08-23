import Foundation

/// The one definition of "how close am I to being stopped".
///
/// ## Why it exists
///
/// Three surfaces answered this question and two of them disagreed.
///
/// `MenuBarLabel` counts only the caps that gate *all* work — the 5-hour session
/// and the all-models week — and deliberately leaves out the per-model weekly
/// cap, because exhausting it does not lock you out: it forces a fallback to
/// another model. `throttle-statusline.sh`'s own fallback does the same.
///
/// `StatuslineService` took the maximum of all three, under a comment claiming
/// it used "exactly the rule the menu-bar popover uses, so the statusline never
/// disagrees with the app". Measured 2026-08-22 on this Mac: the scoped cap sat
/// at 100%, so every terminal on the machine showed a red `100%` — for a limit
/// that was not blocking anything — while the menu bar showed the true figure.
/// The statusline also ignored Codex, which the menu bar counts.
///
/// A comment asserting two things agree is not a mechanism. This is.
enum UsagePressure {

    struct Reading: Sendable, Equatable {
        /// 0…1. The most-loaded cap that can actually stop work.
        let fraction: Double
        /// When that cap resets, when the source knows it.
        let resetsAt: Date?
        /// True when it came from the provider rather than local math.
        let isExact: Bool

        var percent: Int { Int((fraction * 100).rounded()) }
    }

    /// The binding pressure across every provider.
    ///
    /// The per-model weekly cap is **excluded on purpose** — see above. It is
    /// still shown as its own row everywhere; it just never becomes the headline.
    static func binding(
        snapshot: UsageSnapshot,
        exact: ExactSnapshot?,
        codex: CodexUsageSnapshot?
    ) -> Reading? {
        var readings: [Reading] = []

        if let fresh = exact, fresh.isFresh() {
            for window in [fresh.fiveHour, fresh.sevenDay] {
                readings.append(Reading(fraction: Double(window.utilization) / 100.0,
                                        resetsAt: window.resetsAt, isExact: true))
            }
        } else {
            for window in [snapshot.session5h, snapshot.weeklyAll] {
                guard let pct = window.percentUsed else { continue }
                // Local rolling-window math has no authoritative reset instant;
                // it has a countdown, which is the best it can honestly offer.
                readings.append(Reading(
                    fraction: pct,
                    resetsAt: window.resetInSeconds > 0
                        ? Date().addingTimeInterval(TimeInterval(window.resetInSeconds)) : nil,
                    isExact: false))
            }
        }

        if let codex, codex.isFresh(), let pressure = codex.highestPressure {
            readings.append(Reading(fraction: pressure, resetsAt: nil, isExact: true))
        }

        return readings.max { $0.fraction < $1.fraction }
    }
}
