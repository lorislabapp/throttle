import AppKit
import UserNotifications

extension Notification.Name {
    /// Posted (userInfo["tab"] = UUID string) when the user taps a "session is
    /// waiting" notification, or when the Cockpit should focus a session.
    static let cockpitFocusSession = Notification.Name("throttle.cockpitFocusSession")
}

/// Local notification when a **hidden** Cockpit session's `claude` blocks on a
/// question — so you don't lose the prompt while working in another window.
/// Tapping it brings Throttle forward and focuses that session. Local only, no
/// network, no accounts (keeps the "everything stays on your Mac" USP).
@MainActor
final class CockpitNotifier: NSObject {
    static let shared = CockpitNotifier()

    private weak var appState: AppState?
    private var authorized = false
    private var requested = false

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
        if authorized {
            post(project: project, question: question, tabID: tabID)
            return
        }
        guard !requested else { return }   // asked once, declined → stay quiet
        requested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.authorized = granted
                // First grant: deliver the prompt that triggered the request.
                if granted { self?.post(project: project, question: question, tabID: tabID) }
            }
        }
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
