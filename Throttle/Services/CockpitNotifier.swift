import AppKit
import UserNotifications

/// `UNNotificationRequest` is immutable but not annotated Sendable by the SDK.
private final class SendableNotificationRequest: @unchecked Sendable {
    let value: UNNotificationRequest

    init(_ value: UNNotificationRequest) {
        self.value = value
    }
}

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
    nonisolated private static let readFirewallCategory = "THROTTLE_READ_FIREWALL"
    nonisolated private static let deployReadFirewallAction = "THROTTLE_DEPLOY_READ_FIREWALL"

    private weak var appState: AppState?

    override private init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let deploy = UNNotificationAction(
            identifier: Self.deployReadFirewallAction,
            title: "Deploy local firewall",
            options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.readFirewallCategory,
                                   actions: [deploy], intentIdentifiers: [])
        ])
    }

    /// Called from MultiCockpitModel.start so the tap handler can reopen the
    /// Cockpit window if it was closed. Does NOT request permission — we defer
    /// that to the first time a background session actually needs you, so the
    /// system dialog appears in-context rather than on cockpit open.
    func activate(appState: AppState) {
        self.appState = appState
    }

    /// A session that was running on the edge box is no longer reported by it.
    /// Reuses the question path so the message lands wherever the user already
    /// watches for attention — the failure mode being fixed is silence, so this
    /// deliberately does not invent a quieter channel of its own.
    func notifyRemoteSessionEnded(project: String) {
        notifyWaiting(project: project,
                      question: "Session ended on the box — its work is still on disk there.",
                      tabID: UUID())
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
                    let granted = (try? await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound])) == true
                    if granted {
                        self.post(project: project, question: question, tabID: tabID)
                    } else {
                        self.surfaceDenied()
                    }
                case .denied:
                    self.surfaceDenied()
                @unknown default:
                    break
                }
            }
        }
    }

    /// Generic rules-engine notification (e.g. the Opus token-cap auto-pause).
    /// Same live-status gating as notifyWaiting; no tab deep-link payload.
    func notifyRule(title: String, body: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            Self.enqueue(
                UNNotificationRequest(identifier: "throttle-rule-\(UUID().uuidString)",
                                      content: content, trigger: nil))
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
                Self.enqueue(req)
            }
        }
    }

    /// Throttle auto-hibernated idle sessions to reclaim RAM under memory
    /// pressure. One aggregate banner (never one per session) so the user knows
    /// what happened and that it's reversible (tabs wake via `--resume`).
    func notifyAutoHibernate(
        count: Int,
        freedBytes: UInt64,
        resumeContextTokens: Int = 0,
        resumeRebuildEUR: Double = 0
    ) {
        guard count > 0 else { return }
        let freed = ByteCountFormatter.string(fromByteCount: Int64(freedBytes), countStyle: .memory)
        var parts: [String] = []
        if freedBytes > 0 { parts.append("Freed ~\(freed)") }
        if resumeContextTokens > 0 {
            let tokens = resumeContextTokens >= 1_000
                ? "~\(resumeContextTokens / 1_000)k input tokens"
                : "~\(resumeContextTokens) input tokens"
            parts.append(String(format: "resume may rebuild %@ (≈€%.2f)", tokens, resumeRebuildEUR))
        } else {
            parts.append("reopen a tab to resume it with full context")
        }
        let body = parts.joined(separator: " — ") + "."
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
                Self.enqueue(req)
            }
        }
    }

    /// The agent exited twice in quick succession, so Throttle stopped relaunching
    /// it and suspended input on that tab. Worth a sound: unlike a background
    /// reclaim, this one is waiting on a decision, and until it is made the pane
    /// is a shell wearing a session's clothes.
    func notifyAgentExited(project: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                guard status == .authorized || status == .provisional else { return }
                let content = UNMutableNotificationContent()
                content.title = "\(project): the agent keeps exiting"
                content.body = "Throttle stopped relaunching it and suspended typing on that tab, "
                    + "so nothing lands in the shell underneath. Resume it or switch to the shell."
                let req = UNNotificationRequest(identifier: "cockpit-agent-exited-\(project)",
                                                content: content, trigger: nil)
                Self.enqueue(req)
            }
        }
    }

    /// Froze idle sessions under crowding (not real RAM pressure): SIGSTOP keeps
    /// resident pages but stops token burn, and waking is instant with NO
    /// `claude --resume` — so, unlike hibernate, zero re-send and no "resuming will
    /// consume your limits" prompt. Silent; the tab wakes the moment you focus it.
    func notifyAutoPause(count: Int) {
        guard count > 0 else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                guard status == .authorized || status == .provisional else { return }
                let content = UNMutableNotificationContent()
                content.title = "Paused \(count) idle session\(count == 1 ? "" : "s")"
                content.body = "Frozen to stop burn — focus a tab to resume instantly (no tokens, no reload)."
                content.sound = nil   // silent — background reclaim, fully reversible
                let req = UNNotificationRequest(identifier: "cockpit-autopause",
                                                content: content, trigger: nil)
                Self.enqueue(req)
            }
        }
    }

    /// Throttle auto-trimmed idle transcripts (opt-in). One aggregate, silent
    /// banner — the trim is lossless + reversible (whole-file backups in
    /// ~/.claude/throttle-backups; pointers rehydrate via throttle_expand_pointer).
    func notifyAutoTrim(count: Int, tokensSaved: Int) {
        guard count > 0 else { return }
        let tok = tokensSaved >= 1000 ? "~\(tokensSaved / 1000)K" : "~\(tokensSaved)"
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                guard status == .authorized || status == .provisional else { return }
                let content = UNMutableNotificationContent()
                content.title = "Trimmed \(count) idle transcript\(count == 1 ? "" : "s")"
                content.body = "≈\(tok) tokens lighter on resume — reversible (backups kept)."
                content.sound = nil
                let req = UNNotificationRequest(identifier: "cockpit-autotrim",
                                                content: content, trigger: nil)
                Self.enqueue(req)
            }
        }
    }

    /// Non-blocking, actionable menu-bar toast for a measured high-waste project.
    /// The config is only touched from the explicit notification action.
    func notifyReadFirewall(project: String, projectPath: String, summary: ReadFirewallScanner.Summary) {
        guard summary.highWaste else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                guard status == .authorized || status == .provisional else { return }
                let content = UNMutableNotificationContent()
                content.title = "\(project) is high-waste"
                let loaded = ByteCountFormatter.string(fromByteCount: Int64(summary.loadedBytes),
                                                       countStyle: .file)
                content.body = "\(summary.heavyTurns) sequential-read turn(s), \(loaded) loaded. Add a 100% local read firewall?"
                content.sound = nil
                content.categoryIdentifier = Self.readFirewallCategory
                content.userInfo = ["readFirewallProjectPath": projectPath]
                let key = ContentStore.sha256Hex(Data(projectPath.utf8)).prefix(12)
                let request = UNNotificationRequest(identifier: "read-firewall-\(key)",
                                                    content: content, trigger: nil)
                Self.enqueue(request)
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

    nonisolated private static func enqueue(_ request: UNNotificationRequest) {
        let request = SendableNotificationRequest(request)
        Task {
            _ = try? await UNUserNotificationCenter.current().add(request.value)
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
        Self.enqueue(req)
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
        let projectPath = response.notification.request.content.userInfo["readFirewallProjectPath"] as? String
        let deployFirewall = response.actionIdentifier == CockpitNotifier.deployReadFirewallAction
        completionHandler()   // call synchronously; UI work below (non-Sendable handler must not cross actors)
        Task { @MainActor in
            if deployFirewall, let projectPath {
                do {
                    _ = try ReadFirewallInstaller.install(projectPath: projectPath)
                    CockpitNotifier.shared.notifyRule(
                        title: "Local read firewall deployed",
                        body: "mcp-local-rag was added to \(URL(fileURLWithPath: projectPath).lastPathComponent)/.mcp.json. Restart Claude Code to load it.")
                } catch {
                    CockpitNotifier.shared.notifyRule(
                        title: "Read firewall not changed",
                        body: error.localizedDescription)
                }
            }
            if let appState = CockpitNotifier.shared.appState {
                CockpitWindowController.shared.show(appState: appState)
            }
            NSApp.activate(ignoringOtherApps: true)
            if let tab { NotificationCenter.default.post(name: .cockpitFocusSession, object: nil,
                                                         userInfo: ["tab": tab]) }
        }
    }
}
