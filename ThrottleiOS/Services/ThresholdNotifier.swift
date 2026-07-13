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

    private static let firedKey = "ThrottleThresholdFiredV2"
    private static let iso = ISO8601DateFormatter()

    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Current authorization, so a Settings screen can show the real state and offer
    /// re-request (or a jump to system Settings if the user previously denied).
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func evaluate(_ snap: ThrottleMirrorSnapshot) {
        let w = snap.bindingWindow
        let level = w.utilization >= 95 ? 95 : (w.utilization >= 80 ? 80 : 0)
        guard level > 0 else { return }

        let resetKey = w.resetsAt.map { Self.iso.string(from: $0) } ?? "none"
        let key = "\(level)@\(resetKey)"
        // Track every fired (level, reset-window) key in a small capped set so
        // crossing 80 then 95 both fire once, and neither re-fires within the window.
        let store = UserDefaults(suiteName: MirrorStorage.appGroupID) ?? .standard
        var fired = Set(store.stringArray(forKey: Self.firedKey) ?? [])
        guard !fired.contains(key) else { return }
        fired.insert(key)
        if fired.count > 8 { fired = Set(fired.suffix(8)) }
        store.set(Array(fired), forKey: Self.firedKey)

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
