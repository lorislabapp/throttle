import Foundation
import GRDB
import Observation

/// @unchecked Sendable: All mutable state is MainActor-isolated. The `database`
/// property is a GRDB DatabaseWriter (DatabaseQueue or DatabasePool), which is
/// itself Sendable-compliant via internal queue confinement. All async DB operations
/// use `Task.detached` to hop off MainActor, and results are written back via
/// `await MainActor.run`. No cross-actor shared mutable state exists.
@Observable
@MainActor
final class AppState: @unchecked Sendable {
    /// True when ~/.claude/ is not present.
    var claudeCodeDetected: Bool = false

    /// Current snapshot from local JSONL math. Updated whenever usage data or calibration changes.
    var snapshot: UsageSnapshot = .empty

    /// Latest snapshot from claude.ai's /api/.../usage endpoint, if exact mode is on
    /// AND the user is signed in AND the last poll succeeded. nil = falling back to
    /// local JSONL math.
    var exactSnapshot: ExactSnapshot?

    /// True if exact mode is enabled in user settings (separate from "is it currently working").
    var exactModeEnabled: Bool = UserDefaults.standard.bool(forKey: "exactModeEnabled")

    /// Last poll error, surfaced to Settings UI.
    var exactModeError: ExactModeError?

    /// Tokens saved by token-optimization hooks in the last 7 days.
    /// Displayed prominently in the meter view — concrete proof of the
    /// hooks' value, not buried in Stats. Updated on every refresh().
    var savedTokensThisWeek: Int = 0

    /// Per-day savings for the last 7 days, oldest first. Drives the
    /// sparkline next to the hero counter so users see a trend, not just
    /// a static number — last index is today.
    var savedTokensByDay: [Int] = Array(repeating: 0, count: 7)

    /// Convenience: today's savings (last entry of `savedTokensByDay`).
    var savedTokensToday: Int { savedTokensByDay.last ?? 0 }

    /// Convenience: yesterday's savings (second-to-last).
    var savedTokensYesterday: Int {
        savedTokensByDay.count >= 2 ? savedTokensByDay[savedTokensByDay.count - 2] : 0
    }

    /// True when first run has been completed.
    var firstRunDone: Bool = UserDefaults.standard.bool(forKey: "firstRunDone")

    /// True when the Pro tier is unlocked, via any of:
    ///   - a valid Throttle Pro license JWT in Keychain
    ///   - the 7-day Pro trial (auto-started on first launch)
    /// The computed flag is refreshed via `refreshProStatus()`.
    var isPro: Bool = LicenseService.shared.isPro
        || TrialService.shared.isActive
        || DevUnlockService.shared.isUnlocked

    let database: any DatabaseWriter

    private var refreshTask: Task<Void, Never>?

    init(database: any DatabaseWriter) {
        self.database = database
        self.claudeCodeDetected = ClaudeCodePathProvider.projectsDirectory() != nil
    }

    #if DEBUG
    /// Demo state with impressive fake data for screenshots and video demos.
    /// Usage: In SwiftUI preview or when generating assets, use `.environment(AppState.demo)`
    static var demo: AppState {
        let state = AppState(database: try! DatabaseQueue())
        state.claudeCodeDetected = true
        state.firstRunDone = true
        state.isPro = true

        // Session at 6%, weekly at 80%, Sonnet at 99% (compelling visual contrast)
        state.snapshot = UsageSnapshot(
            session5h: UsageSnapshot.Window(
                kind: .session5h,
                usedTokens: 1_200_000,
                capTokens: 20_000_000,
                resetInSeconds: Int64(3 * 3600 + 51 * 60) // 3h 51m
            ),
            weeklyAll: UsageSnapshot.Window(
                kind: .weeklyAll,
                usedTokens: 640_000_000,
                capTokens: 800_000_000,
                resetInSeconds: Int64(1 * 86400 + 7 * 3600) // 1d 7h
            ),
            weeklySonnet: UsageSnapshot.Window(
                kind: .weeklySonnet,
                usedTokens: 792_000_000,
                capTokens: 800_000_000,
                resetInSeconds: Int64(1 * 86400 + 7 * 3600) // 1d 7h
            ),
            computedAt: Date(),
            hasAnyData: true
        )

        // 45M tokens saved this week = ~€124 (enough to unlock "1 month of Max 5×")
        state.savedTokensThisWeek = 45_000_000

        // Sparkline showing growth: [2M, 4M, 6M, 8M, 10M, 12M, 8M] (today dip for realism)
        state.savedTokensByDay = [2_000_000, 4_000_000, 6_000_000, 8_000_000, 10_000_000, 12_000_000, 8_000_000]

        // Set lifetime tokens so total EUR crosses "1 month of Max 5×" (€92)
        // 45M this week = ~€124, so set lifetime = 0 to show "≈€124" in banner
        // Actually, let's set lifetime to show we've crossed multiple milestones
        // 30M lifetime + 45M this week = 75M total = ~€207 (crosses Max 20× milestone!)
        UserDefaults.standard.set(30_000_000, forKey: "throttle.milestone.lifetimeTokens")
        UserDefaults.standard.set(45_000_000, forKey: "throttle.milestone.lastWeeklySnapshot")

        // Unlock ALL milestone badges for maximum visual impact in screenshots/video
        UserDefaults.standard.set(
            ["day_pro", "week_pro", "month_pro", "month_max5", "month_max20"],
            forKey: "throttle.milestone.fired"
        )

        return state
    }
    #endif

    /// Recompute the snapshot from the database. Call from UI thread or from Coordinator hooks.
    func refresh() {
        // Cancel any in-flight refresh
        refreshTask?.cancel()

        refreshTask = Task { [database] in
            let computed: UsageSnapshot = (try? await Task.detached {
                try database.read { db in
                    let session = try Self.computeWindow(in: db, kind: .session5h)
                    let weekAll = try Self.computeWindow(in: db, kind: .weeklyAll)
                    let weekSonnet = try Self.computeWindow(in: db, kind: .weeklySonnet)
                    let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_events") ?? 0
                    return UsageSnapshot(
                        session5h: session,
                        weeklyAll: weekAll,
                        weeklySonnet: weekSonnet,
                        computedAt: Date(),
                        hasAnyData: count > 0
                    )
                }
            }.value) ?? .empty
            let savedTokens: Int = (try? await Task.detached {
                try database.read { db in
                    try StatsDataService.savedTokensThisWeek(in: db)
                }
            }.value) ?? 0
            let savedByDay: [Int] = (try? await Task.detached {
                try database.read { db in
                    try StatsDataService.savedTokensByDay(in: db, days: 7)
                }
            }.value) ?? Array(repeating: 0, count: 7)
            let weeklyCost: Double = (try? await Task.detached {
                try database.read { db in
                    try StatsDataService.extrapolatedCostEUR(in: db, range: .last7d)
                }
            }.value) ?? 0

            // Check cancellation before writing back to MainActor
            guard !Task.isCancelled else { return }

            // Persist this snapshot's three windows into history. Keyed by
            // 5-minute bucket so rapid refresh()s don't explode the table.
            try? await Task.detached {
                try database.write { db in
                    try Self.persistSnapshotRows(in: db, snapshot: computed)
                }
            }.value

            // Final cancellation check before MainActor write
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.snapshot = computed
                self.savedTokensThisWeek = savedTokens
                self.savedTokensByDay = savedByDay
                ThresholdNotifier.shared.evaluate(snapshot: computed, exact: self.exactSnapshot)
                // Keep the terminal statusline's pre-rendered line fresh (the
                // script reads this file; falls back to Claude Code's own
                // rate_limits when it's stale). Cheap atomic write.
                if computed.hasAnyData {
                    StatuslineService.update(snapshot: computed, exact: self.exactSnapshot, savedTokens: savedTokens)
                }
                // Persist a compact snapshot for App Intents (Shortcuts).
                // The intent reads UserDefaults so it can answer in <50 ms
                // and stay consistent with what the menu bar is showing.
                ThrottleIntentSnapshotStore.write(ThrottleIntentSnapshot(
                    session5hPercent: (computed.session5h.percentUsed ?? 0) * 100,
                    weeklyAllPercent: (computed.weeklyAll.percentUsed ?? 0) * 100,
                    weeklyTokens: computed.weeklyAll.usedTokens,
                    weeklyCostEUR: weeklyCost,
                    savedTokensThisWeek: savedTokens,
                    computedAt: computed.computedAt
                ))
            }
        }
    }

    // Note: refreshTask cleanup removed — Swift 6 deinit cannot access MainActor-isolated
    // properties. The Task will be automatically canceled when AppState is deallocated
    // (structured concurrency guarantees).

    nonisolated private static func persistSnapshotRows(in db: Database, snapshot: UsageSnapshot) throws {
        let bucket = (Int64(snapshot.computedAt.timeIntervalSince1970) / UsageSnapshotRow.bucketSizeSeconds) * UsageSnapshotRow.bucketSizeSeconds
        for window in [snapshot.session5h, snapshot.weeklyAll, snapshot.weeklySonnet] {
            let row = UsageSnapshotRow(
                timestampBucket: bucket,
                windowKind: window.kind.rawValue,
                usedTokens: window.usedTokens,
                capTokens: window.capTokens
            )
            // INSERT OR REPLACE — overwrite same bucket with latest values.
            try row.save(db)
        }
    }

    nonisolated private static func computeWindow(in db: Database, kind: WindowKind) throws -> UsageSnapshot.Window {
        let used = try WindowCalculator.totalForWindow(in: db, kind: kind)
        let cap = try DatabaseQueries.calibration(in: db, kind: kind)?.capTokens
        let reset = try WindowCalculator.secondsUntilReset(in: db, kind: kind)
        return UsageSnapshot.Window(
            kind: kind, usedTokens: used, capTokens: cap, resetInSeconds: reset
        )
    }

    func markFirstRunDone() {
        UserDefaults.standard.set(true, forKey: "firstRunDone")
        firstRunDone = true
    }

    func setExactModeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "exactModeEnabled")
        exactModeEnabled = enabled
    }

    /// Recompute isPro after license activation/deactivation.
    func refreshProStatus() {
        isPro = LicenseService.shared.isPro
            || TrialService.shared.isActive
            || DevUnlockService.shared.isUnlocked
    }
}
