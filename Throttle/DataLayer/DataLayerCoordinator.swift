import Foundation
import GRDB
import OSLog

/// Orchestrates ColdStartScanner, LiveFileWatcher, and HourlySweeper.
/// Single instance owned by AppDelegate, started on launch, stopped on terminate.
@MainActor
final class DataLayerCoordinator {
    private let database: any DatabaseWriter
    private var watcher: LiveFileWatcher?
    private var sweeper: HourlySweeper?
    private var claudeCodeDetectionTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.lorislab.throttle", category: "DataLayer")

    /// Notifies UI when usage data changes. UI subscribes via SwiftUI @Observable patterns.
    var onUsageChanged: (@MainActor () -> Void)?

    /// Reference to AppState for updating claudeCodeDetected flag
    weak var appState: AppState?

    /// Tracks paths currently being processed to prevent reentrancy
    private var inFlightPaths: Set<String> = []

    /// Debouncer for onUsageChanged to prevent UI refresh storms
    private var usageChangedDebouncer: DispatchWorkItem?
    private let usageChangedQueue = DispatchQueue(label: "com.lorislab.throttle.debounce", qos: .userInitiated)

    init(database: any DatabaseWriter) {
        self.database = database
    }

    func start() async {
        guard let root = ClaudeCodePathProvider.projectsDirectory() else {
            logger.notice("Claude Code not detected; data layer idle")
            return
        }

        // Cold start
        do {
            let scanner = ColdStartScanner(database: database)
            try scanner.scan(rootDirectory: root)
        } catch {
            logger.error("Cold start scan failed: \(error.localizedDescription, privacy: .public)")
        }

        await MainActor.run { onUsageChanged?() }

        // Live watcher
        watcher = LiveFileWatcher(rootURL: root) { [weak self] url in
            Task { @MainActor in
                await self?.handleFileChange(url: url)
            }
        }
        watcher?.start()

        // Hourly sweeper
        sweeper = HourlySweeper { [weak self] in
            Task { @MainActor in
                await self?.runSweep()
            }
        }
        sweeper?.start()

        // Periodic Claude Code detection refresh (every 5 seconds)
        // Fixes first-run UI stuck on "not detected" even after ~/.claude/projects/ appears
        claudeCodeDetectionTask = Task { [weak self, weak appState] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                let detected = ClaudeCodePathProvider.projectsDirectory() != nil
                await MainActor.run {
                    appState?.claudeCodeDetected = detected
                }
            }
        }
    }

    func stop() {
        watcher?.stop()
        sweeper?.stop()
        claudeCodeDetectionTask?.cancel()
        usageChangedDebouncer?.cancel()
        watcher = nil
        sweeper = nil
        claudeCodeDetectionTask = nil
        usageChangedDebouncer = nil
    }

    private func handleFileChange(url: URL) async {
        // Use standardizedFileURL.path consistently with ColdStartScanner — handles
        // the macOS /private/var/ symlink so file_state keys remain stable.
        let canonicalPath = url.standardizedFileURL.path

        // Prevent reentrancy: if this path is already being processed, skip
        guard !inFlightPaths.contains(canonicalPath) else {
            return
        }
        inFlightPaths.insert(canonicalPath)
        defer { inFlightPaths.remove(canonicalPath) }

        do {
            let priorOffset: Int64 = try await Task.detached { [database] in
                try database.read { db in
                    try FileState.fetchOne(db, key: canonicalPath)?.lastOffset ?? 0
                }
            }.value
            let result = try SessionFileParser.parse(url: url, fromByteOffset: priorOffset)
            try await Task.detached { [database] in
                try database.write { db in
                    for var event in result.events {
                        try event.insert(db)
                    }
                    try DatabaseQueries.upsertFileState(
                        in: db, path: canonicalPath, offset: result.bytesRead,
                        mtime: Int64(Date().timeIntervalSince1970))
                }
            }.value
            notifyUsageChanged()
        } catch {
            logger.error("Live update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Debounced notification: coalesces rapid file changes to one UI refresh per 500ms
    private func notifyUsageChanged() {
        usageChangedDebouncer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.onUsageChanged?()
            }
        }
        usageChangedDebouncer = work
        usageChangedQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func runSweep() async {
        guard let root = ClaudeCodePathProvider.projectsDirectory() else { return }
        do {
            let scanner = ColdStartScanner(database: database)
            try scanner.scan(rootDirectory: root)
            onUsageChanged?()
        } catch {
            logger.error("Hourly sweep failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
