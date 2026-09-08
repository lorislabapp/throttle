import AppKit
import GRDB
import OSLog
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState: AppState
    let database: any DatabaseWriter  // Accept both DatabasePool and DatabaseQueue
    let coordinator: DataLayerCoordinator
    let savingsIngester: SavingsIngester
    let codexIngester: CodexUsageIngester
    let traycer = TraycerReceiver.shared   // local OTLP receiver (opt-in; started below)
    lazy var updater = UpdaterService.shared
    let logger = AppLogger.app
    var licenseRenewalTimer: Timer?
    var codexUsageTimer: Timer?
    var researchVaultWorkbenchTestWindow: NSWindow?
    var globalRAGOnboardingTestWindow: NSWindow?

    /// App-hosted tests already initialize the state/database they exercise, but
    /// must not start production listeners, CloudKit, login items or singleton
    /// ownership. Xcode 27 no longer guarantees the legacy environment marker.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") })
    }

    /// UI hosts can also be launched directly, without XCTest injection.
    /// Use the same boundary for initialization, scenes and the whole lifecycle.
    static var isIsolatedHost: Bool {
        isRunningTests
            || CommandLine.arguments.contains("-globalRAGOnboardingTest")
            || CommandLine.arguments.contains("-researchVaultWorkbenchTest")
            || CommandLine.arguments.contains("-researchVaultApprovalTest")
    }

    override init() {
        FileHandle.standardError.write(Data("[AppDelegate.init] start\n".utf8))
        // Check for -demo launch argument for screen recordings & screenshots
        let isDemoMode = CommandLine.arguments.contains("-demo")
        let isGlobalRAGTestHost = CommandLine.arguments.contains("-globalRAGOnboardingTest")

        do {
            if Self.isIsolatedHost {
                // UI qualification hosts must be hermetic in every configuration.
                // In particular, an ad hoc Release must never prompt for the
                // production license item in Keychain merely to render a view.
                self.database = try DatabaseQueue()
                try Migrations.register(on: database)
                self.coordinator = DataLayerCoordinator(database: database)
                self.savingsIngester = SavingsIngester(database: database)
                self.codexIngester = CodexUsageIngester(database: database)
                self.appState = AppState(database: database, readsLicenseState: false)
                super.init()
                if isGlobalRAGTestHost {
                    GlobalRAGService.baseDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("throttle-global-rag-ui-test-\(UUID().uuidString)", isDirectory: true)
                }
                self.coordinator.onUsageChanged = {}
            } else if isDemoMode {
                #if DEBUG
                // Demo mode: in-memory database with fake data
                self.database = try DatabaseQueue()
                self.coordinator = DataLayerCoordinator(database: database)
                self.savingsIngester = SavingsIngester(database: database)
                self.codexIngester = CodexUsageIngester(database: database)
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
                FileHandle.standardError.write(Data("[AppDelegate.init] before openDatabaseSync\n".utf8))
                self.database = try Self.openDatabaseSync()
                FileHandle.standardError.write(Data("[AppDelegate.init] after openDatabaseSync\n".utf8))
                self.appState = AppState(database: database)
                FileHandle.standardError.write(Data("[AppDelegate.init] after AppState init\n".utf8))
                self.coordinator = DataLayerCoordinator(database: database)
                self.savingsIngester = SavingsIngester(database: database)
                self.codexIngester = CodexUsageIngester(database: database)
                super.init()
                self.coordinator.appState = appState
                self.coordinator.onUsageChanged = { [weak self] in
                    self?.appState.refresh()
                }
                FileHandle.standardError.write(Data("[AppDelegate.init] done\n".utf8))
            }
        } catch {
            // Fail-fast: if we can't open the DB, the app is non-functional.
            fatalError("Failed to initialize database: \(error)")
        }
    }

    var quitPending = false

    static func openDatabaseSync() throws -> DatabasePool {
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
    static var singletonLockFD: Int32 = -1

    /// Single-instance guard via an advisory file lock (`flock`), NOT an
    /// `NSRunningApplication` bundle-id count. The CLI sub-modes (`--mcp-server`,
    /// `--tokopt-hook`, the proxy modes) live in the SAME signed bundle and so
    /// share its bundle identifier; Claude Code keeps one or more
    /// `Throttle --mcp-server` children alive per connected session. A bundle-id
    /// count therefore reads ≥2 and the menubar app would terminate itself even
    /// though no other *GUI* instance exists. Those CLI modes `exit()` in
    /// `main.swift` before `ThrottleApp.main()`, so they never reach this code —
    /// an flock taken only here counts GUI instances exactly.
    static func acquireSingletonLock() -> Bool {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("com.lorislab.throttle.singleton.lock")
        // O_CLOEXEC: without it, any child process forked off this one (e.g. the
        // Cockpit's embedded shell) inherits this fd. A long-lived terminal session
        // then holds the flock forever, even after Throttle itself has quit —
        // blocking every future launch with a false "already running".
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return true }   // fail-open: never block launch on a lock error
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false                      // another GUI instance holds it
        }
        singletonLockFD = fd                  // keep open for the process lifetime
        return true
    }
}

extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}
