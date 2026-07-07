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
    private let traycer = TraycerReceiver.shared   // local OTLP receiver (opt-in; started below)
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

    /// User re-opened Throttle (double-clicked the app while it's already running).
    /// LSUIElement menu-bar apps do NOT get this on the login-item launch, so the
    /// Cockpit opens only on an intentional reopen — never on boot auto-launch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        CockpitWindowController.shared.show(appState: appState)
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isDemoMode = CommandLine.arguments.contains("-demo")

        // In demo mode, skip all background services and just show the UI with fake data
        guard !isDemoMode else {
            logger.notice("🎬 DEMO MODE: Skipping all background services")
            return
        }

        // Listen for cross-process commands from App Intents / Shortcuts / Focus
        // Filters (pause/resume/quiet) and apply anything queued before launch.
        ThrottleCommandChannel.startObserving()

        // Raise the per-process FD limit. macOS defaults to ~256 soft;
        // LiveFileWatcher used to open one descriptor per session JSONL,
        // and on heavy users with thousands of subagent files (now
        // filtered out, but defensively cap higher anyway) we'd hit
        // EMFILE which masquerades as "directory not readable".
        // Heal the tokopt hook's exec path if it points at a stale build (e.g. an
        // old DerivedData path after installing to /Applications or a Sparkle
        // update). No-op if the hook isn't installed or is already current.
        TokoptHookInstaller.reconcile()
        TranscriptMemoryInstaller.reconcile()   // heal a stale throttle-memory --mcp-server path (e.g. dev build → /Applications)
        TraycerEnvInstaller.reconcile()          // heal drifted OTLP env keys — only if the user opted the export in

        // Traycer: local OTLP receiver for €-per-skill attribution. Opt-in
        // (Settings → the export writes full command lines to the local usage.db).
        // Fail-open: a bind conflict on 4318 disables it silently.
        if UserDefaults.standard.bool(forKey: "throttleTraycerEnabled") {
            traycer.start(writer: database)
        }
        OutputStyleManager.resyncManagedTemplates()   // heal stale managed output-style files after an app upgrade changed a template body

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
        ContentStore.purge()    // age out trimmed-payload blobs (CMV, ~30d)

        // Auto-trim idle transcripts (opt-in, OFF by default). Reuses the manual
        // trimmer's lossless + reversible apply path (backup + validation + post-write
        // verify + rehydratable pointers); a 10-min idle floor never touches a session
        // you're actively resuming. Off-main, images-only, best-effort.
        if UserDefaults.standard.bool(forKey: "throttleAutoTrimEnabled") {
            Task.detached(priority: .utility) {
                let r = ContextTrimmerService.autoTrimIdle()
                if r.count > 0 {
                    await CockpitNotifier.shared.notifyAutoTrim(count: r.count, tokensSaved: r.tokensSaved)
                }
            }
        }

        // Throttle Autopilot — keep the Claude Code setup optimized, by default,
        // system-wide. Off-main; debounced to ~once/day; every action reversible
        // and logged (Settings → Autopilot → Review & undo).
        if appState.isPro {   // Autopilot is a Pro feature
            Task.detached(priority: .utility) { _ = AutopilotService.runIfDue() }
        }

        // Semantic auto-index (opt-in, OFF by default): keep each project's corpus
        // fresh for throttle_semantic_search without manual --index-repo. Skipped
        // under memory pressure (16 GB Mac). Gate read on main, heavy work off-main.
        // Consult a SYNCHRONOUS snapshot too: at cold start on an already-swapping
        // Mac the kernel hasn't posted a pressure event yet, so `isQuiet` reads a
        // stale `.normal` — the false negative that let the heavy embedding pass
        // start precisely when the machine was worst (MEM-M01).
        if SemanticAutoIndexer.isEnabled, !MemoryPressureMonitor.shared.isQuiet,
           !SystemMemoryService.sample().underPressure {
            Task.detached(priority: .utility) {
                let roots = ProjectsService.listProjects().compactMap { $0.projectPath }
                _ = SemanticAutoIndexer.run(roots: roots, enabled: true, memoryQuiet: false,
                                            embedder: NLEmbeddingProvider())
            }
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
        traycer.stop()
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
        case "pause":   ThrottleCommandChannel.enqueue(.pauseAll)
        case "resume":  ThrottleCommandChannel.enqueue(.resumeAll)
        case "quiet":   ThrottleCommandChannel.enqueue(.quietOn)
        case "unquiet": ThrottleCommandChannel.enqueue(.quietOff)
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
        // Bound per-connection memory on the 16 GB constraint (MEM-M02): a
        // menu-bar app's reads are bursty, not parallel-heavy, so 2 readers is
        // plenty, and each SQLite connection's page cache is capped (~2 MB) via
        // a negative cache_size (KiB). Writer keeps its own connection.
        var config = Configuration()
        config.maximumReaderCount = 2
        // @Sendable: GRDB runs this on its own serial DB queue. Without it the
        // closure inherits AppDelegate's @MainActor isolation and macOS 27's
        // runtime isolation check traps (SIGTRAP in dispatch_assert_queue).
        config.prepareDatabase { @Sendable db in
            try db.execute(sql: "PRAGMA cache_size = -2000")
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        try Migrations.register(on: pool)
        return pool
    }

    /// Held for the GUI process's whole lifetime so the advisory lock stays taken.
    private static var singletonLockFD: Int32 = -1

    /// Single-instance guard via an advisory file lock (`flock`), NOT an
    /// `NSRunningApplication` bundle-id count. The CLI sub-modes (`--mcp-server`,
    /// `--tokopt-hook`, the proxy modes) live in the SAME signed bundle and so
    /// share its bundle identifier; Claude Code keeps one or more
    /// `Throttle --mcp-server` children alive per connected session. A bundle-id
    /// count therefore reads ≥2 and the menubar app would terminate itself even
    /// though no other *GUI* instance exists. Those CLI modes `exit()` in
    /// `main.swift` before `ThrottleApp.main()`, so they never reach this code —
    /// an flock taken only here counts GUI instances exactly.
    private static func acquireSingletonLock() -> Bool {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("com.lorislab.throttle.singleton.lock")
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }   // fail-open: never block launch on a lock error
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false                      // another GUI instance holds it
        }
        singletonLockFD = fd                  // keep open for the process lifetime
        return true
    }
}

private extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}
