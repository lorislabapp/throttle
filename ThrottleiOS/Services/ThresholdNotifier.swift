import Foundation
import UserNotifications
import ThrottleShared

/// Fires a local notification when the binding window crosses 80% / 95%.
/// Runs on-device from the last synced snapshot — works even with the Mac off,
/// and needs no push server. De-duped per (level, reset-window) so you get at
/// most one 80% and one 95% alert per rolling window.
@MainActor
final class ThresholdNotifier {
    static let shared = ThresholdNotifier()
    private init() {}

    private static let firedKey = "ThrottleThresholdFiredV1"

    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    func evaluate(_ snap: ThrottleMirrorSnapshot) {
        let w = snap.bindingWindow
        let level = w.utilization >= 95 ? 95 : (w.utilization >= 80 ? 80 : 0)
        guard level > 0 else { return }

        let resetKey = w.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none"
        let key = "\(level)@\(resetKey)"
        // Persist the last-fired key so we don't re-alert across launches.
        let store = UserDefaults(suiteName: MirrorStorage.appGroupID) ?? .standard
        guard store.string(forKey: Self.firedKey) != key else { return }
        store.set(key, forKey: Self.firedKey)

        let content = UNMutableNotificationContent()
        content.title = level >= 95 ? "Claude usage critical" : "Claude usage high"
        var body = "Your binding window is at \(w.utilization)%."
        if let cd = MirrorUI.countdown(to: w.resetsAt) { body += " Resets in \(cd)." }
        content.body = body
        content.sound = .default

        let req = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
