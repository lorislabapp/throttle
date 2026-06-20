import AppKit
import GRDB
import OSLog
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState: AppState
    private let database: any DatabaseWriter  // Accept both DatabasePool and DatabaseQueue
    private let coordinator: DataLayerCoordinator
    private let savingsIngester: SavingsIngester
    private let updater = UpdaterService.shared
    private let logger = AppLogger.app

    override init() {
        // Check for -demo launch argument for screen recordings & screenshots
        let isDemoMode = CommandLine.arguments.contains("-demo")

        do {
            if isDemoMode {
                #if DEBUG
                // Demo mode: in-memory database with fake data
                self.database = try DatabaseQueue()
                self.coordinator = DataLayerCoordinator(database: database)
                self.savingsIngester = SavingsIngester(database: database)
                self.appState = AppState.demo  // Must come after super.init()
                super.init()
                // No-op: demo data is static, no need to refresh
                self.coordinator.onUsageChanged = {}
                print("🎬 DEMO MODE: Throttle running with fake data for screen recording")
                #else
                fatalError("-demo flag only works in Debug builds")
                #endif
            } else {
                // Normal mode: real database
                self.database = try Self.openDatabaseSync()
                self.appState = AppState(database: database)
                self.coordinator = DataLayerCoordinator(database: database)
                self.savingsIngester = SavingsIngester(database: database)
                super.init()
                self.coordinator.appState = appState
                self.coordinator.onUsageChanged = { [weak self] in
                    self?.appState.refresh()
                }
            }
        } catch {
            // Fail-fast: if we can't open the DB, the app is non-functional.
            fatalError("Failed to initialize database: \(error)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isDemoMode = CommandLine.arguments.contains("-demo")

        // In demo mode, skip all background services and just show the UI with fake data
        guard !isDemoMode else {
            logger.notice("🎬 DEMO MODE: Skipping all background services")
            return
        }

        // Raise the per-process FD limit. macOS defaults to ~256 soft;
        // LiveFileWatcher used to open one descriptor per session JSONL,
        // and on heavy users with thousands of subagent files (now
        // filtered out, but defensively cap higher anyway) we'd hit
        // EMFILE which masquerades as "directory not readable".
        var rlim = rlimit()
        if getrlimit(RLIMIT_NOFILE, &rlim) == 0 {
            let target = min(rlim.rlim_max, rlim_t(10_240))
            if target > rlim.rlim_cur {
                rlim.rlim_cur = target
                setrlimit(RLIMIT_NOFILE, &rlim)
            }
        }

        // Skip the singleton check under XCTest — the test host bundle launches a
        // second Throttle.app process to load the test bundle, and the singleton
        // lock would terminate it before tests can run.
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !isRunningTests {
            guard Self.acquireSingletonLock() else {
                logger.notice("Another Throttle instance is already running. Quitting.")
                NSApp.terminate(nil)
                return
            }
        }

        logger.notice("Throttle launched (\(Bundle.main.shortVersion, privacy: .public))")
        AppLogger.appendToFile("Throttle launched (\(Bundle.main.shortVersion))")

        // Wire ExactModeService → AppState. The service runs whenever the user
        // has enabled exact mode AND is signed in to claude.ai. When polling
        // returns a fresh snapshot, the dropdown promotes its values over the
        // local JSONL math.
        let exact = ExactModeService.shared
        exact.onSnapshot = { [weak self] snap in
            Task { @MainActor in
                self?.appState.exactSnapshot = snap
                self?.appState.exactModeError = nil
                self?.appState.anchorCalibration(from: snap)   // make the local estimate track server truth
                self?.appState.refreshStatusline()   // keep the terminal line in sync with exact
            }
        }
        exact.onError = { [weak self] err in
            Task { @MainActor in
                // Non-recoverable errors (notSignedIn) — drop the snapshot so the UI
                // falls back to local math instead of showing stale data.
                if err == .notSignedIn {
                    self?.appState.exactSnapshot = nil
                }
                self?.appState.exactModeError = err
            }
        }

        savingsIngester.onIngest = { [weak self] in
            self?.appState.refresh()
        }
        savingsIngester.start()

        CrashReporter.shared.start()
        TokoptHook.purgeRaw()   // age out raw command-output dumps (M16)

        // Throttle Autopilot — keep the Claude Code setup optimized, by default,
        // system-wide. Off-main; debounced to ~once/day; every action reversible
        // and logged (Settings → Autopilot → Review & undo).
        if appState.isPro {   // Autopilot is a Pro feature
            Task.detached(priority: .utility) { _ = AutopilotService.runIfDue() }
        }

        Task { @MainActor in
            await coordinator.start()
            appState.refresh()
            if appState.exactModeEnabled {
                // Safari Bridge handles missing-Safari / not-signed-in via
                // .failure on each poll — start unconditionally; the UI
                // surfaces errors when polling fails.
                exact.start()
            }
        }

        // Re-evaluate Pro status whenever the dev-unlock sheet succeeds
        // so the UI immediately reflects the change without needing a
        // restart. Posted by `DevUnlockSheet.tryUnlock` after a valid
        // key + Keychain write.
        NotificationCenter.default.addObserver(
            forName: .devUnlockChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.appState.refreshProStatus() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MultiCockpitModel.shared.stop()        // hard-kill every cockpit session subtree (C01)
        CaffeineService.shared.setActive(false) // release the power assertion (M04)
        coordinator.stop()
        savingsIngester.stop()
        logger.notice("Throttle quitting")
    }

    /// Handle deep links: `throttle://activate?key=THROTTLE-XXXX-XXXX-XXXX-XXXX`.
    /// Lets the purchase email link auto-activate Pro instead of asking the user
    /// to copy the key, find the menu bar pill, and click Paste license key.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleDeepLink(url)
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "throttle" else {
            logger.notice("Ignoring URL with unknown scheme: \(url.scheme ?? "nil", privacy: .public)")
            return
        }
        let host = url.host?.lowercased()
        switch host {
        case "activate":
            // ?key=THROTTLE-… in either query or path component.
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let key = comps?.queryItems?.first(where: { $0.name == "key" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard let key, key.hasPrefix("THROTTLE-") else {
                logger.notice("activate URL missing or malformed key")
                return
            }
            Task { @MainActor in
                let result = await LicenseService.shared.activate(key: key)
                switch result {
                case .success:
                    self.appState.refreshProStatus()
                    self.notifyActivation(success: true, message: "Throttle Pro activated.")
                case .failure(let err):
                    self.notifyActivation(success: false, message: self.describeActivationError(err))
                }
            }
        case "cockpit":
            Task { @MainActor in CockpitWindowController.shared.show(appState: self.appState) }
        default:
            logger.notice("Ignoring throttle:// URL with unknown host: \(host ?? "nil", privacy: .public)")
        }
    }

    private func notifyActivation(success: Bool, message: String) {
        let alert = NSAlert()
        alert.messageText = success ? "Throttle Pro" : "Activation failed"
        alert.informativeText = message
        alert.alertStyle = success ? .informational : .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func describeActivationError(_ err: LicenseService.ActivationError) -> String {
        switch err {
        case .invalidKey:           return "Invalid license key."
        case .machineLimitReached:  return "Already activated on 3 Macs. Deactivate one first."
        case .revoked:              return "License revoked. Contact support@lorislab.fr."
        case .verificationFailed:   return "Server response failed signature check. Don't trust this network."
        case .network(let m):       return "Network error: \(m)"
        case .server(let code):     return "Server error \(code). Try again later."
        case .decode(let m):        return "Couldn't decode response: \(m)"
        }
    }

    private static func openDatabaseSync() throws -> DatabasePool {
        let url = try DatabaseManager.databaseURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let pool = try DatabasePool(path: url.path)
        try Migrations.register(on: pool)
        return pool
    }

    private static func acquireSingletonLock() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.lorislab.throttle"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        return running.count == 1
    }
}

private extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}
