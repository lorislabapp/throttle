import AppKit
import GRDB
import OSLog
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState: AppState
    private let database: DatabasePool
    private let coordinator: DataLayerCoordinator
    private let savingsIngester: SavingsIngester
    private let updater = UpdaterService.shared
    private let logger = AppLogger.app

    override init() {
        do {
            self.database = try Self.openDatabaseSync()
            self.appState = AppState(database: database)
            self.coordinator = DataLayerCoordinator(database: database)
            self.savingsIngester = SavingsIngester(database: database)
            super.init()
            self.coordinator.onUsageChanged = { [weak self] in
                self?.appState.refresh()
            }
        } catch {
            // Fail-fast: if we can't open the DB, the app is non-functional.
            fatalError("Failed to initialize database: \(error)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            self?.appState.exactSnapshot = snap
            self?.appState.exactModeError = nil
        }
        exact.onError = { [weak self] err in
            // Non-recoverable errors (notSignedIn) — drop the snapshot so the UI
            // falls back to local math instead of showing stale data.
            if err == .notSignedIn {
                self?.appState.exactSnapshot = nil
            }
            self?.appState.exactModeError = err
        }

        savingsIngester.start()

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
        savingsIngester.stop()
        logger.notice("Throttle quitting")
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
