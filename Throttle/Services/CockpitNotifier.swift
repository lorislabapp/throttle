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

    /// claude hit the usage cap on a session — notify so you know WHICH project is
    /// blocked and when it frees up, even from another window. Same live-status
    /// gating as notifyWaiting (never trust an in-memory latch).
    func notifyRateLimited(project: String, until: Date?, tabID: UUID) {
        let body: String
        if let until {
            let f = DateFormatter(); f.timeStyle = .short
            body = "Usage limit reached — frees up at \(f.string(from: until))."
        } else {
            body = "Usage limit reached on this session."
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                guard status == .authorized || status == .provisional else { return }
                let content = UNMutableNotificationContent()
                content.title = "\(project) is rate-limited"
                content.body = body
                content.sound = .default
                content.userInfo = ["tab": tabID.uuidString]
                let req = UNNotificationRequest(identifier: "cockpit-ratelimit-\(tabID.uuidString)",
                                                content: content, trigger: nil)
                UNUserNotificationCenter.current().add(req)
            }
        }
    }

    /// Throttle auto-hibernated idle sessions to reclaim RAM under memory
    /// pressure. One aggregate banner (never one per session) so the user knows
    /// what happened and that it's reversible (tabs wake via `--resume`).
    func notifyAutoHibernate(count: Int, freedBytes: UInt64) {
        guard count > 0 else { return }
        let freed = ByteCountFormatter.string(fromByteCount: Int64(freedBytes), countStyle: .memory)
        let body = freedBytes > 0
            ? "Freed ~\(freed) — reopen a tab to resume it with full context."
            : "Reopen a tab to resume it with full context."
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                guard status == .authorized || status == .provisional else { return }
                let content = UNMutableNotificationContent()
                content.title = "Hibernated \(count) idle session\(count == 1 ? "" : "s")"
                content.body = body
                content.sound = nil   // silent — this is a background reclaim, not an alert
                let req = UNNotificationRequest(identifier: "cockpit-autohibernate",
                                                content: content, trigger: nil)
                UNUserNotificationCenter.current().add(req)
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
