import AppIntents
import Foundation
import ThrottleShared

/// Siri / Shortcuts / Spotlight surface for the iOS companion. Every intent reads
/// the latest mirrored snapshot straight from the App Group, so Siri answers in
/// milliseconds even when the app isn't running — no launch, no network. The Mac
/// is the source of truth; these report whatever it last published.
private enum MirrorIntentReader {
    static func snapshot() -> ThrottleMirrorSnapshot? {
        let defaults = UserDefaults(suiteName: MirrorStorage.appGroupID)
        guard let data = defaults?.data(forKey: MirrorStorage.latestSnapshotKey) else { return nil }
        return try? ThrottleMirrorSnapshot.decoded(from: data)
    }
}

private let noData = "No usage yet — open Throttle on your iPhone once, on the same Apple Account as your Mac, so it can sync."

struct GetUsageIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Claude usage"
    static let description = IntentDescription(
        "Your Mac's current Claude Code 5-hour and 7-day usage, as a percentage of your plan limits.")

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        guard let s = MirrorIntentReader.snapshot() else {
            return .result(value: 0, dialog: IntentDialog(stringLiteral: noData))
        }
        return .result(
            value: Double(s.bindingWindow.utilization),
            dialog: "Claude usage: 5-hour \(s.fiveHour.utilization)%, 7-day \(s.sevenDay.utilization)%.")
    }
}

struct GetTimeToCapIntent: AppIntent {
    static let title: LocalizedStringResource = "Get time until Claude cap"
    static let description = IntentDescription(
        "How much of your binding Claude window is used and when it resets — so you know how long you can keep going.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let s = MirrorIntentReader.snapshot() else {
            return .result(dialog: IntentDialog(stringLiteral: noData))
        }
        let w = s.bindingWindow
        guard let reset = w.resetsAt, reset > Date() else {
            return .result(dialog: "You're at \(w.utilization)% of your binding Claude window.")
        }
        let mins = Int(reset.timeIntervalSinceNow / 60)
        let when = mins >= 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins)m"
        return .result(dialog: "You're at \(w.utilization)% — this window resets in \(when).")
    }
}

struct GetWeeklyTokensIntent: AppIntent {
    static let title: LocalizedStringResource = "Get weekly Claude tokens"
    static let description = IntentDescription("Weighted token count for the last 7 days on your Mac.")

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        guard let s = MirrorIntentReader.snapshot() else {
            return .result(value: 0, dialog: IntentDialog(stringLiteral: noData))
        }
        return .result(value: s.weeklyTokens,
                       dialog: "\(s.weeklyTokens.formatted(.number)) weighted tokens this week.")
    }
}

struct GetWeeklyCostIntent: AppIntent {
    static let title: LocalizedStringResource = "Get reference weekly Claude cost"
    static let description = IntentDescription(
        "What the last 7 days would cost at Anthropic's developer-API rates — a reference number; your subscription is flat-rate.")

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        guard let s = MirrorIntentReader.snapshot() else {
            return .result(value: 0, dialog: IntentDialog(stringLiteral: noData))
        }
        return .result(value: s.weeklyCostEUR,
                       dialog: "€\(String(format: "%.2f", s.weeklyCostEUR)) at developer-API rates this week.")
    }
}

struct ThrottleiOSAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetTimeToCapIntent(),
            phrases: [
                "How much Claude do I have left in \(.applicationName)",
                "When does my Claude reset in \(.applicationName)",
                "Ask \(.applicationName) how long until my cap"
            ],
            shortTitle: "Time to cap",
            systemImageName: "gauge.with.needle")
        AppShortcut(
            intent: GetUsageIntent(),
            phrases: [
                "Show my \(.applicationName) usage",
                "What's my Claude usage in \(.applicationName)"
            ],
            shortTitle: "Claude usage",
            systemImageName: "speedometer")
        AppShortcut(
            intent: GetWeeklyTokensIntent(),
            phrases: ["Get my weekly tokens from \(.applicationName)"],
            shortTitle: "Weekly tokens",
            systemImageName: "number.circle")
        AppShortcut(
            intent: GetWeeklyCostIntent(),
            phrases: ["Get my weekly Claude cost from \(.applicationName)"],
            shortTitle: "Weekly cost",
            systemImageName: "eurosign.circle")
    }
}
