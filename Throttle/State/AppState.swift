import Foundation
import GRDB
import Observation

/// All mutable state is MainActor-isolated; the `database` (GRDB DatabaseWriter)
/// is Sendable via internal queue confinement, and async DB work hops off via
/// `Task.detached` + `await MainActor.run`. A `@MainActor` class is implicitly
/// Sendable, so the prior `@unchecked Sendable` was redundant (L01).
@Observable
@MainActor
final class AppState {
    /// True when ~/.claude/ is not present.
    var claudeCodeDetected: Bool = false

    /// Codex is considered available once its local data directory exists. This
    /// does not claim that a login is valid or that a fresh quota event exists.
    var codexDetected: Bool = false

    /// Latest provider-emitted Codex usage observation. It remains visible when
    /// stale, but stale limits are excluded from the menu-bar headline.
    var codexUsageSnapshot: CodexUsageSnapshot?

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
    /// API-equivalent value of the last 7 days, already computed off-main by
    /// `refresh()` for the Shortcuts snapshot. Stored so the menu-bar label can
    /// show it without touching the database from a render pass — the mistake
    /// that produced the 3.2.88 runaway.
    var weeklyCostEUR: Double = 0
    /// EUR value of `savedTokensThisWeek`, priced at the input rate of the
    /// models this account actually ran — not a flat blended constant.
    var savedValueEURThisWeek: Double = 0

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
    private var codexRefreshTask: Task<Void, Never>?

    init(database: any DatabaseWriter) {
        self.database = database
        self.claudeCodeDetected = ClaudeCodePathProvider.projectsDirectory() != nil
        self.codexDetected = FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        )
    }

    #if DEBUG
    /// Demo state with impressive fake data for screenshots and video demos.
    /// Usage: In SwiftUI preview or when generating assets, use `.environment(AppState.demo)`
    static var demo: AppState {
        let state = AppState(database: try! DatabaseQueue())
        state.claudeCodeDetected = true
        state.codexDetected = true
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

    /// Refresh Codex independently from the Claude database pipeline. Separating
    /// the tasks prevents a busy Claude file watcher from continuously cancelling
    /// the bounded Codex rollout read.
    func refreshCodexUsage() {
        codexRefreshTask?.cancel()
        codexRefreshTask = Task {
            let snapshot = await Task.detached(priority: .utility) {
                CodexUsageService.latestSnapshot()
            }.value
            guard !Task.isCancelled else { return }
            self.codexUsageSnapshot = snapshot
            self.codexDetected = self.codexDetected || snapshot != nil
        }
    }

    /// Anchor the local cap of each window to the server-true utilization from a
    /// fresh exact snapshot, so the local estimate (used between exact refreshes
    /// and when exact is stale) actually tracks reality. Without this the cap
    /// stays at "auto" (rolling-max + 5%), which is unrelated to Anthropic's real
    /// metering — the cause of the 12%-local vs 92%-exact divergence.
    /// Skips windows with a user-set "manual" cap (highest precedence).
    func anchorCalibration(from exact: ExactSnapshot) {
        let pairs: [(WindowKind, Int)] = [
            (.session5h, exact.fiveHour.utilization),
            (.weeklyAll, exact.sevenDay.utilization),
            (.weeklySonnet, exact.sevenDaySonnet.utilization)
        ]
        let database = self.database
        Task { [weak self] in
            try? await Task.detached {
                try database.write { db in
                    for (kind, pct) in pairs where pct > 0 {
                        if let cal = try? DatabaseQueries.calibration(in: db, kind: kind),
                           cal.source == "manual" { continue }
                        try? CalibrationEngine.anchor(in: db, kind: kind, observedPercent: pct)
                    }
                }
            }.value
            self?.refresh()   // recompute local % against the freshly anchored caps
        }
    }

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
                    // EXISTS, not COUNT(*): the value is only ever used as the
                    // boolean `hasAnyData`. Measured on this Mac's 682 k-row
                    // table — COUNT(*) 438 ms cold / 3.3-6.2 ms warm, EXISTS
                    // 0.05 ms — and `refresh()` is driven by the file watcher,
                    // so it runs several times a second while sessions write.
                    let hasAny = try Bool.fetchOne(
                        db, sql: "SELECT EXISTS(SELECT 1 FROM usage_events)") ?? false
                    return UsageSnapshot(
                        session5h: session,
                        weeklyAll: weekAll,
                        weeklySonnet: weekSonnet,
                        computedAt: Date(),
                        hasAnyData: hasAny
                    )
                }
            }.value) ?? .empty
            let derived = await Self.loadDerived(from: database)
            let savedTokens = derived.saved.tokens
            let savedByDay = derived.savedByDay
            let weeklyCost = derived.weeklyCost

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
                self.weeklyCostEUR = weeklyCost
                self.savedValueEURThisWeek = derived.saved.eur
                if savedTokens > 0 {
                    MilestoneTracker.shared.setRatePerMillion(derived.saved.eur / Double(savedTokens) * 1_000_000)
                }
                ThresholdNotifier.shared.evaluate(snapshot: computed, exact: self.exactSnapshot)
                // Keep the terminal statusline's pre-rendered line fresh (the
                // script reads this file; falls back to Claude Code's own
                // rate_limits when it's stale). Cheap atomic write.
                if computed.hasAnyData {
                    StatuslineService.update(snapshot: computed, exact: self.exactSnapshot,
                                             codex: self.codexUsageSnapshot, savedEUR: derived.saved.eur)
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
                // Mirror the same values to the iOS companion. MirrorFanout ships
                // the snapshot to every enabled transport (private CloudKit DB today,
                // a LAN peer link next); each is opt-in and debounces internally, so
                // this stays cheap and fail-open on every refresh.
                MirrorFanout.shared.publish(self.mirrorSnapshot(
                    weeklyTokens: computed.weeklyAll.usedTokens,
                    weeklyCostEUR: weeklyCost,
                    savedTokensThisWeek: savedTokens))
            }
        }
    }

    /// Re-render the terminal statusline from current state — cheap, no DB.
    /// Called on every exact-mode poll so the line never lags the menu bar
    /// (same exact-vs-local freshness rule, so they always agree).
    @MainActor
    func refreshStatusline() {
        guard snapshot.hasAnyData else { return }
        StatuslineService.update(snapshot: snapshot, exact: exactSnapshot,
                                 codex: codexUsageSnapshot, savedEUR: savedValueEURThisWeek)
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

    /// The figures `refresh()` derives from the database off the main actor.
    /// Extracted so the single read that produces both the saved-token count and
    /// its euro value sits next to the other two rather than inline.
    private struct Derived {
        var saved: (tokens: Int, eur: Double) = (0, 0)
        var savedByDay: [Int] = Array(repeating: 0, count: 7)
        var weeklyCost: Double = 0
    }

    nonisolated private static func loadDerived(from database: any DatabaseWriter) async -> Derived {
        var out = Derived()
        // One read for the pair: the token count and what it is worth at the
        // input rate of the models actually run this week.
        out.saved = (try? await Task.detached {
            try database.read { db in
                let tokens = try StatsDataService.savedTokensThisWeek(in: db)
                return (tokens, try StatsDataService.savedValueEUR(tokens: tokens, in: db))
            }
        }.value) ?? (0, 0)
        out.savedByDay = (try? await Task.detached {
            try database.read { try StatsDataService.savedTokensByDay(in: $0, days: 7) }
        }.value) ?? Array(repeating: 0, count: 7)
        out.weeklyCost = (try? await Task.detached {
            try database.read { try StatsDataService.extrapolatedCostEUR(in: $0, range: .last7d) }
        }.value) ?? 0
        return out
    }

    nonisolated private static func computeWindow(in db: Database, kind: WindowKind) throws -> UsageSnapshot.Window {
        // Resolved once and passed to both: the default argument reads
        // `UserDefaults`, so evaluating it twice lets a `remember()` landing
        // between the two calls compute the total for one model and the reset
        // for another. It also stops the two unscoped kinds reading a
        // preference they never use.
        // A derived token can name a word no model id contains. Only the query
        // can tell, so ask once here and let the labels reflect the answer.
        // `CalibrationEngine` asks the same question, so the cap this number is
        // divided by is calibrated under the same scope. Both halves come back
        // from one read: comparing against `ScopedCapModel.match` again would
        // re-read the global, and a `remember()` landing between the two reads
        // would flip the label to the default over a correctly scoped number.
        let scope = try WindowCalculator.resolvedScope(in: db, kind: kind)
        if kind == .weeklySonnet {
            ScopedCapModel.recordTokenMatchedNothing(scope.resolved != scope.stated)
        }
        let scoped = scope.resolved
        let used = try WindowCalculator.totalForWindow(in: db, kind: kind, scoped: scoped)
        let cap = try DatabaseQueries.calibration(in: db, kind: kind)?.capTokens
        let reset = try WindowCalculator.secondsUntilReset(in: db, kind: kind, scoped: scoped)
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
