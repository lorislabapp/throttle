import AppKit
import GRDB
import OSLog
import SwiftUI

extension AppDelegate {

    /// Clicking Throttle's Dock icon while the app is already running always brings
    /// back the Cockpit, even when every auxiliary window was previously closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if Self.isIsolatedHost {
            if let researchVaultWorkbenchTestWindow {
                researchVaultWorkbenchTestWindow.makeKeyAndOrderFront(nil)
                return true
            }
            if let globalRAGOnboardingTestWindow {
                globalRAGOnboardingTestWindow.makeKeyAndOrderFront(nil)
                return true
            }
            return false
        }
        CockpitWindowController.shared.show(appState: appState)
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileHandle.standardError.write(Data("[applicationDidFinishLaunching] start\n".utf8))
        let isDemoMode = CommandLine.arguments.contains("-demo")

        // In demo mode, skip all background services and just show the UI with fake data
        guard !isDemoMode else {
            logger.notice("🎬 DEMO MODE: Skipping all background services")
            return
        }
        guard !Self.isIsolatedHost else {
            showTestHostWindow()
            logger.notice("Isolated host detected: skipping production background services")
            return
        }
        // Production-only services must follow the host boundary, including
        // retention (which deletes old files) and the opt-in remote build host.
        MenuBarUpdateGuard.start()
        RetentionService.startPeriodicSweeps()
        CapabilityHostService.shared.restoreIfEnabled()
        _ = updater
        FileHandle.standardError.write(Data("[applicationDidFinishLaunching] past demo check\n".utf8))

        // Listen for cross-process commands from App Intents / Shortcuts / Focus
        // Filters (pause/resume/quiet) and apply anything queued before launch.
        FileHandle.standardError.write(Data("[applicationDidFinishLaunching] before ThrottleCommandChannel\n".utf8))
        ThrottleCommandChannel.startObserving()
        FileHandle.standardError.write(Data("[applicationDidFinishLaunching] after ThrottleCommandChannel\n".utf8))

        // Raise the per-process FD limit. macOS defaults to ~256 soft;
        // LiveFileWatcher used to open one descriptor per session JSONL,
        // and on heavy users with thousands of subagent files (now
        // filtered out, but defensively cap higher anyway) we'd hit
        // EMFILE which masquerades as "directory not readable".
        // Heal the tokopt hook's exec path if it points at a stale build (e.g. an
        // old DerivedData path after installing to /Applications or a Sparkle
        // update). No-op if the hook isn't installed or is already current.
        FileHandle.standardError.write(Data("[applicationDidFinishLaunching] before installers\n".utf8))
        TokoptHookInstaller.reconcile()
        TranscriptMemoryInstaller.reconcile()   // heal a stale throttle-memory --mcp-server path (e.g. dev build → /Applications)
        TraycerEnvInstaller.reconcile()          // heal drifted OTLP env keys — only if the user opted the export in
        FileHandle.standardError.write(Data("[applicationDidFinishLaunching] after installers\n".utf8))

        // Traycer: local OTLP receiver for €-per-skill attribution. Opt-in
        // (Settings → the export writes full command lines to the local usage.db).
        // Fail-open: a bind conflict on 4318 disables it silently.
        FileHandle.standardError.write(Data("[applicationDidFinishLaunching] before Traycer\n".utf8))
        if UserDefaults.standard.bool(forKey: "throttleTraycerEnabled") {
            traycer.start(writer: database)
        }
        FileHandle.standardError.write(Data("[applicationDidFinishLaunching] after Traycer\n".utf8))

        // Provider-neutral local context bridge. It stays loopback-only and cheap;
        // WebKit is created only when the explicit web preference is enabled and a
        // render is requested. The same bridge hosts bounded embedded-model drafts.
        FileHandle.standardError.write(Data("[applicationDidFinishLaunching] before WebRenderBridge\n".utf8))
        WebRenderBridge.shared.start(writer: database)
        FileHandle.standardError.write(Data("[applicationDidFinishLaunching] after WebRenderBridge\n".utf8))

        // iOS companion mirror: publish live usage/cockpit state to the user's
        // private CloudKit DB. Opt-in; fail-open (no iCloud / no entitlement →
        // silently disabled, meter unaffected). Fed from AppState.refresh via
        // MirrorFanout — register the transport always (so it holds the freshest
        // snapshot), but only arm the network side when the user opted in.
        MirrorFanout.shared.register(CloudKitPublisher.shared)
        MirrorFanout.shared.register(PeerTransport.shared)   // LAN fast path (Bonjour+TLS-PSK)
        if UserDefaults.standard.bool(forKey: "throttleiCloudMirrorEnabled") {
            CloudKitPublisher.shared.start()
            PeerTransport.shared.start()
        }

        FileHandle.standardError.write(Data("[applicationDidFinishLaunching] before OutputStyleManager\n".utf8))
        OutputStyleManager.resyncManagedTemplates()   // heal stale managed output-style files after an app upgrade changed a template body
        FileHandle.standardError.write(Data("[applicationDidFinishLaunching] after OutputStyleManager\n".utf8))

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
        guard Self.acquireSingletonLock() else {
            logger.notice("Another Throttle instance is already running. Quitting.")
            NSApp.terminate(nil)
            return
        }

        logger.notice("Throttle launched (\(Bundle.main.shortVersion, privacy: .public))")
        AppLogger.appendToFile("Throttle launched (\(Bundle.main.shortVersion))")

        startLicenseRenewal()

        // Wire ExactModeService → AppState. The service runs whenever the user
        // has enabled exact mode AND is signed in to claude.ai. When polling
        // returns a fresh snapshot, the dropdown promotes its values over the
        // local JSONL math.
        let exact = configureExactMode()

        savingsIngester.onIngest = { [weak self] in
            self?.appState.refresh()
        }
        savingsIngester.start()
        codexIngester.onIngest = { [weak self] in
            self?.appState.refresh()
        }
        codexIngester.start()

        CrashReporter.shared.start()
        TokoptHook.purgeRaw()   // age out raw command-output dumps (M16)
        ContentStore.purge()    // age out trimmed-payload blobs (CMV, ~30d)

        // Read Firewall: inspect only local execution logs and surface one
        // non-blocking, actionable toast for the most recent high-waste workspace.
        // No project config is changed until the user accepts the notification.
        notifyReadFirewallIfNeeded()

        // Auto-trim idle transcripts (opt-in, OFF by default). Reuses the manual
        // trimmer's lossless + reversible apply path (backup + validation + post-write
        // verify + rehydratable pointers); a 10-min idle floor never touches a session
        // you're actively resuming. Off-main, images-only, best-effort.
        if UserDefaults.standard.bool(forKey: "throttleAutoTrimEnabled") {
            Task.detached(priority: .utility) {
                let r = ContextTrimmerService.autoTrimIdle()
                // `r` is a tuple whose first member is named `count`, not a
                // collection. SwiftLint's empty_count autocorrect rewrote this
                // to `!r.isEmpty` and broke the build.
                // swiftlint:disable:next empty_count
                if r.count > 0 {
                    await CockpitNotifier.shared.notifyAutoTrim(count: r.count, tokensSaved: r.tokensSaved)
                }
            }
        }

        // Adaptive keep-alive for the embedded local model (2026-08 mix research):
        // weights reload in seconds, the user's swapping sessions don't recover —
        // so under critical pressure the model is never kept resident.
        MemoryPressureMonitor.shared.onPressureRise { level in
            guard level == .critical else { return }
            Task { await EmbeddedModelRuntime.shared.unload() }
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
            appState.refreshCodexUsage()
            if appState.exactModeEnabled {
                // Safari Bridge handles missing-Safari / not-signed-in via
                // .failure on each poll — start unconditionally; the UI
                // surfaces errors when polling fails.
                exact.start()
            }
        }

        // Codex has no separate account API integration here: refresh the latest
        // provider-emitted local token_count event on a modest cadence. The reader
        // touches only the last three date directories and a bounded file tail.
        codexUsageTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.appState.refreshCodexUsage() }
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
}
