import AppIntents
import Foundation

/// Compact snapshot of the meter's current values, persisted to
/// `UserDefaults.standard` every time `AppState.refresh()` recomputes
/// the windows. App Intents (which Apple's Shortcuts.app dispatches into
/// the host process) read from here so they can answer in tens of
/// milliseconds without re-running the full JSONL math, and so the
/// answer is consistent with what the menu bar is currently showing.
///
/// Writes happen on the main actor; reads are safe from any thread —
/// `UserDefaults` is process-shared and the payload is plain JSON.
struct ThrottleIntentSnapshot: Codable, Sendable {
    let session5hPercent: Double      // 0…100
    let weeklyAllPercent: Double      // 0…100
    let weeklyTokens: Int             // weighted tokens, last 7d
    let weeklyCostEUR: Double         // dev-API rate
    let savedTokensThisWeek: Int      // hooks/router savings
    let computedAt: Date

    static let empty = ThrottleIntentSnapshot(
        session5hPercent: 0,
        weeklyAllPercent: 0,
        weeklyTokens: 0,
        weeklyCostEUR: 0,
        savedTokensThisWeek: 0,
        computedAt: .distantPast
    )
}

enum ThrottleIntentSnapshotStore {
    private static let key = "ThrottleIntentSnapshotV1"

    static func write(_ snap: ThrottleIntentSnapshot) {
        guard let data = try? JSONEncoder().encode(snap) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func read() -> ThrottleIntentSnapshot {
        guard let data = UserDefaults.standard.data(forKey: key),
              let snap = try? JSONDecoder().decode(ThrottleIntentSnapshot.self, from: data)
        else { return .empty }
        return snap
    }
}

// MARK: - Intents

struct GetUsageIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Claude Code usage"
    static let description = IntentDescription(
        "Returns the current 5-hour session and 7-day window as percentages of your Claude Pro/Max plan limits."
    )

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        let snap = ThrottleIntentSnapshotStore.read()
        let session = Int(snap.session5hPercent.rounded())
        let weekly  = Int(snap.weeklyAllPercent.rounded())
        return .result(
            value: snap.session5hPercent,
            dialog: "Session 5h: \(session)%, weekly: \(weekly)%."
        )
    }
}

struct GetWeeklyTokensIntent: AppIntent {
    static let title: LocalizedStringResource = "Get weekly token usage"
    static let description = IntentDescription(
        "Returns the weighted token count for the last 7 days. Cache reads bill at ~10% of input, cache writes at ~125% — Throttle weights all of them into one comparable number."
    )

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        let snap = ThrottleIntentSnapshotStore.read()
        return .result(
            value: snap.weeklyTokens,
            dialog: "\(snap.weeklyTokens.formatted(.number)) weighted tokens this week."
        )
    }
}

struct GetWeeklyCostIntent: AppIntent {
    static let title: LocalizedStringResource = "Get reference weekly cost (EUR)"
    static let description = IntentDescription(
        "Returns what the last 7 days of Claude Code usage would cost at Anthropic's per-token developer-API rates. Reference number — your actual Claude subscription is $20–$200/mo regardless."
    )

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        let snap = ThrottleIntentSnapshotStore.read()
        return .result(
            value: snap.weeklyCostEUR,
            dialog: "€\(String(format: "%.2f", snap.weeklyCostEUR)) at developer-API rates this week."
        )
    }
}

struct GetSavedTokensIntent: AppIntent {
    static let title: LocalizedStringResource = "Get tokens saved this week"
    static let description = IntentDescription(
        "Returns how many tokens your session-start router and pre-compact hooks saved over the last 7 days. Concrete proof your hook setup is doing useful work."
    )

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        let snap = ThrottleIntentSnapshotStore.read()
        return .result(
            value: snap.savedTokensThisWeek,
            dialog: "\(snap.savedTokensThisWeek.formatted(.number)) tokens saved by your hooks this week."
        )
    }
}

// MARK: - Shortcuts provider

struct ThrottleAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetUsageIntent(),
            phrases: [
                "Show my \(.applicationName) usage",
                "Get Claude Code usage from \(.applicationName)"
            ],
            shortTitle: "Claude Code usage",
            systemImageName: "speedometer"
        )
        AppShortcut(
            intent: GetWeeklyTokensIntent(),
            phrases: [
                "Get my weekly tokens from \(.applicationName)",
                "How many tokens have I used in \(.applicationName)"
            ],
            shortTitle: "Weekly tokens",
            systemImageName: "number.circle"
        )
        AppShortcut(
            intent: GetWeeklyCostIntent(),
            phrases: [
                "Get my weekly Claude cost from \(.applicationName)",
                "How much did Claude cost this week in \(.applicationName)"
            ],
            shortTitle: "Weekly cost",
            systemImageName: "eurosign.circle"
        )
        AppShortcut(
            intent: GetSavedTokensIntent(),
            phrases: [
                "Show tokens saved by \(.applicationName)",
                "How many tokens did my hooks save in \(.applicationName)"
            ],
            shortTitle: "Tokens saved",
            systemImageName: "leaf.circle"
        )
    }
}
