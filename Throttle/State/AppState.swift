import Foundation
import GRDB
import Observation

@Observable
@MainActor
final class AppState {
    /// True when ~/.claude/ is not present.
    var claudeCodeDetected: Bool = false

    /// Current snapshot. Updated every time usage data or calibration changes.
    var snapshot: UsageSnapshot = .empty

    /// True when first run has been completed.
    var firstRunDone: Bool = UserDefaults.standard.bool(forKey: "firstRunDone")

    private let database: any DatabaseWriter

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
            await MainActor.run {
                self.snapshot = computed
            }
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
}
