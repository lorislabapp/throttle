import Foundation

/// Reads each runtime's remaining room from what Throttle already tracks, and
/// hands it to `DispatchAdvisor` as plain values.
///
/// The split is the point: this type does the I/O and nothing else, so every rule
/// about what to do with a budget stays in a pure function that a test can drive.
enum DispatchBudget {

    /// Claude's snapshot is written by the running app. Older than this and it
    /// describes a session that may already be over, so it is treated as unknown
    /// rather than quietly stale.
    private static let freshnessWindow: TimeInterval = 600

    static func current(now: Date = Date(),
                        claude: ThrottleIntentSnapshot? = nil,
                        codex: CodexUsageSnapshot? = nil) -> [RuntimeBudget] {
        var budgets: [RuntimeBudget] = []

        let snapshot = claude ?? ThrottleIntentSnapshotStore.read()
        if snapshot.computedAt != .distantPast,
           now.timeIntervalSince(snapshot.computedAt) < freshnessWindow {
            // Worst window wins: a five-hour cap at 100% blocks work just as
            // firmly as an exhausted week.
            budgets.append(RuntimeBudget(
                runtime: .claudeCode,
                usedPercent: max(snapshot.session5hPercent, snapshot.weeklyAllPercent),
                // Throttle does not publish a reset time for Claude, and inventing
                // one would put a fabricated number in front of the user.
                resetsAt: nil))
        }

        if let codexSnapshot = codex ?? CodexUsageService.latestSnapshot(now: now) {
            let windows = [codexSnapshot.primary, codexSnapshot.secondary].compactMap { $0 }
            if let worst = windows.max(by: { $0.usedPercent < $1.usedPercent }) {
                budgets.append(RuntimeBudget(runtime: .codex,
                                             usedPercent: worst.usedPercent,
                                             resetsAt: worst.resetsAt))
            }
        }
        return budgets
    }

    /// What one agent on this task is likely to cost, in euros at reference rates.
    ///
    /// Deliberately crude, and labelled as an estimate everywhere it surfaces: the
    /// number exists so a fan-out multiplier means something, not to bill anyone.
    /// It uses the user's own recent spend per session rather than a table, so it
    /// tracks their actual models and habits.
    static func estimatedAgentCostEUR(sessionsLastWeek: Int,
                                      snapshot: ThrottleIntentSnapshot? = nil) -> Double {
        let usage = snapshot ?? ThrottleIntentSnapshotStore.read()
        guard sessionsLastWeek > 0, usage.weeklyCostEUR > 0 else { return 0 }
        return usage.weeklyCostEUR / Double(sessionsLastWeek)
    }
}
