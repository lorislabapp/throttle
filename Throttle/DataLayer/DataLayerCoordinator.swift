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
    private let logger = Logger(subsystem: "com.lorislab.throttle", category: "DataLayer")

    /// Notifies UI when usage data changes. UI subscribes via SwiftUI @Observable patterns.
    var onUsageChanged: (@MainActor () -> Void)?

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
    }

    func stop() {
        watcher?.stop()
        sweeper?.stop()
        watcher = nil
        sweeper = nil
    }

    private func handleFileChange(url: URL) async {
        // Use standardizedFileURL.path consistently with ColdStartScanner — handles
        // the macOS /private/var/ symlink so file_state keys remain stable.
        let canonicalPath = url.standardizedFileURL.path
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
            onUsageChanged?()
        } catch {
            logger.error("Live update failed: \(error.localizedDescription, privacy: .public)")
        }
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
