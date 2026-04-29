import Foundation
import GRDB
import Observation

@Observable
@MainActor
final class AppState {
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
    var isPro: Bool = LicenseService.shared.isPro || TrialService.shared.isActive

    let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
        self.claudeCodeDetected = ClaudeCodePathProvider.projectsDirectory() != nil
    }

    /// Recompute the snapshot from the database. Call from UI thread or from Coordinator hooks.
    func refresh() {
        Task { [database] in
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
            // Persist this snapshot's three windows into history. Keyed by
            // 5-minute bucket so rapid refresh()s don't explode the table.
            try? await Task.detached {
                try database.write { db in
                    try Self.persistSnapshotRows(in: db, snapshot: computed)
                }
            }.value
            await MainActor.run {
                self.snapshot = computed
                self.savedTokensThisWeek = savedTokens
                self.savedTokensByDay = savedByDay
                ThresholdNotifier.shared.evaluate(snapshot: computed, exact: self.exactSnapshot)
            }
        }
    }

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
        isPro = LicenseService.shared.isPro || TrialService.shared.isActive
    }
}
