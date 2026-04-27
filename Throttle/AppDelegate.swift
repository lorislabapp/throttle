import AppKit
import GRDB
import OSLog
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState: AppState
    private let database: DatabasePool
    private let coordinator: DataLayerCoordinator
    private let logger = AppLogger.app

    override init() {
        do {
            self.database = try Self.openDatabaseSync()
            self.appState = AppState(database: database)
            self.coordinator = DataLayerCoordinator(database: database)
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
        guard Self.acquireSingletonLock() else {
            logger.notice("Another Throttle instance is already running. Quitting.")
            NSApp.terminate(nil)
            return
        }

        logger.notice("Throttle launched (\(Bundle.main.shortVersion, privacy: .public))")
        AppLogger.appendToFile("Throttle launched (\(Bundle.main.shortVersion))")

        Task { @MainActor in
            await coordinator.start()
            appState.refresh()
        }

        // First-run UX: the dropdown surfaces a "Finish setup" CTA when
        // firstRunDone is false. Cleaner than auto-popping a window at launch
        // (which also required a custom URL scheme that we don't ship).
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
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
