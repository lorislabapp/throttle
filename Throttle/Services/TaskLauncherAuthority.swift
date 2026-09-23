import Foundation

extension TaskLauncher {
    /// Every capability is finite even when no budget ledger is configured. An
    /// exact task wall-clock bound narrows the default one-day window.
    static func authorityExpiration(task: PlanTask, issuedAt: Date) -> Date {
        let defaultExpiration = issuedAt.addingTimeInterval(24 * 60 * 60)
        guard let wallClock = task.workContract?.budget.wallClockLimit,
              wallClock.knowledge == .exact,
              wallClock.unit == "seconds",
              let seconds = wallClock.value,
              seconds > 0 else { return defaultExpiration }
        return min(defaultExpiration, issuedAt.addingTimeInterval(TimeInterval(seconds)))
    }
}
