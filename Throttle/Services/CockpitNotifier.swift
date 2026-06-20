import AppKit
import UserNotifications

extension Notification.Name {
    /// Posted (userInfo["tab"] = UUID string) when the user taps a "session is
    /// waiting" notification, or when the Cockpit should focus a session.
    static let cockpitFocusSession = Notification.Name("throttle.cockpitFocusSession")
    /// Posted when a hidden session needs the user but notifications are denied —
    /// the cockpit shows an in-window banner so the feature degrades visibly.
    static let cockpitNotificationsDenied = Notification.Name("throttle.cockpitNotificationsDenied")
}

/// Local notification when a **hidden** Cockpit session's `claude` blocks on a
/// question — so you don't lose the prompt while working in another window.
/// Tapping it brings Throttle forward and focuses that session. Local only, no
/// network, no accounts (keeps the "everything stays on your Mac" USP).
@MainActor
final class CockpitNotifier: NSObject {
    static let shared = CockpitNotifier()

    private weak var appState: AppState?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Called from MultiCockpitModel.start so the tap handler can reopen the
    /// Cockpit window if it was closed. Does NOT request permission — we defer
    /// that to the first time a background session actually needs you, so the
    /// system dialog appears in-context rather than on cockpit open.
    func activate(appState: AppState) {
        self.appState = appState
    }

    func notifyWaiting(project: String, question: String, tabID: UUID) {
        // C02: query the LIVE system status every time — never trust an in-memory
        // "requested/denied" latch. A user who later enables notifications in
        // System Settings then gets them; one early "Don't Allow" no longer
        // permanently and silently kills the feature.
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus   // Sendable enum; don't send `settings` across the actor
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .authorized, .provisional:
                    self.post(project: project, question: question, tabID: tabID)
                case .notDetermined:
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        Task { @MainActor in
                            if granted { self.post(project: project, question: question, tabID: tabID) }
                            else { self.surfaceDenied() }
                        }
                    }
                case .denied:
                    self.surfaceDenied()
                @unknown default:
                    break
                }
            }
        }
    }

    /// Notifications are off but a hidden session needs the user — tell the UI to
    /// show an in-cockpit "turn on notifications" banner (debounced ~2h) so the
    /// feature degrades visibly instead of silently (C02).
    private var lastDeniedNudge = Date.distantPast
    private func surfaceDenied() {
        guard Date().timeIntervalSince(lastDeniedNudge) > 2 * 3600 else { return }
        lastDeniedNudge = Date()
        NotificationCenter.default.post(name: .cockpitNotificationsDenied, object: nil)
    }

    private func post(project: String, question: String, tabID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = "\(project) needs you"
        content.body = question.isEmpty ? "claude is waiting for your input." : question
        content.sound = .default
        content.userInfo = ["tab": tabID.uuidString]
        let req = UNNotificationRequest(identifier: "cockpit-wait-\(tabID.uuidString)",
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

extension CockpitNotifier: UNUserNotificationCenterDelegate {
    // Show the banner even when Throttle is frontmost.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let tab = response.notification.request.content.userInfo["tab"] as? String
        completionHandler()   // call synchronously; UI work below (non-Sendable handler must not cross actors)
        Task { @MainActor in
            if let appState = CockpitNotifier.shared.appState {
                CockpitWindowController.shared.show(appState: appState)
            }
            NSApp.activate(ignoringOtherApps: true)
            if let tab { NotificationCenter.default.post(name: .cockpitFocusSession, object: nil,
                                                         userInfo: ["tab": tab]) }
        }
    }
}
