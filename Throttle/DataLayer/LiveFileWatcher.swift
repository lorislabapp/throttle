import Foundation
import OSLog

/// Watches Claude Code's project directories for `.jsonl` writes and newly-created
/// top-level session transcripts. On any event, calls the handler with the URL that
/// changed. Coalesces bursts via a 250ms debounce per path.
///
/// @unchecked Sendable: All mutable state (`sources`, `debouncers`)
/// is confined to the serial `queue`. Every mutation runs via `queue.async`,
/// so concurrent access is structurally impossible.
final class LiveFileWatcher: @unchecked Sendable {
    private let rootURL: URL
    private let handler: @Sendable (URL) -> Void
    private let logger = Logger(subsystem: "com.lorislab.throttle", category: "LiveFileWatcher")

    private let queue = DispatchQueue(label: "com.lorislab.throttle.watcher", qos: .utility)
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var debouncers: [URL: DispatchWorkItem] = [:]
    private var isRunning = false

    init(rootURL: URL, handler: @escaping @Sendable (URL) -> Void) {
        self.rootURL = rootURL
        self.handler = handler
    }

    func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.isRunning = true
            self.attachAllJsonlFiles()
            self.attachDirectoryWatcher(at: self.rootURL, isRoot: true)
            self.attachProjectDirectoryWatchers()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.isRunning = false
            for src in self.sources.values { src.cancel() }
            self.sources.removeAll()
            self.debouncers.values.forEach { $0.cancel() }
            self.debouncers.removeAll()
        }
    }

    private func attachAllJsonlFiles() {
        let files = ColdStartScanner.discoverJsonlFiles(under: rootURL)
        for file in files {
            attachFile(file)
        }
    }

    private func attachFile(_ url: URL) {
        guard isRunning, sources[url] == nil else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            logger.warning("Failed to open \(url.path, privacy: .public) for watching")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.fired(url: url)
        }
        src.setCancelHandler {
            close(fd)
        }
        sources[url] = src
        src.resume()
    }

    /// A dispatch source on the root does not receive changes made inside an
    /// existing project directory. Watch each first-level project directory as
    /// well, so a newly-created `<session>.jsonl` is discovered immediately.
    /// We intentionally stop at one level: subagent transcripts live deeper and
    /// are excluded by `ColdStartScanner.discoverJsonlFiles`.
    private func attachProjectDirectoryWatchers() {
        guard isRunning,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return }

        for url in entries {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            attachDirectoryWatcher(at: url, isRoot: false)
        }
    }

    private func attachDirectoryWatcher(at url: URL, isRoot: Bool) {
        guard isRunning, sources[url] == nil else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            logger.warning("Failed to open directory \(url.path, privacy: .public) for watching")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.directoryChanged(isRoot: isRoot)
        }
        src.setCancelHandler { close(fd) }
        sources[url] = src
        src.resume()
    }

    private func directoryChanged(isRoot: Bool) {
        // Check if root directory still exists (might have been deleted)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else {
            logger.warning("Root directory \(self.rootURL.path, privacy: .public) no longer exists, stopping watcher")
            stop()
            return
        }

        // The root event may be a newly-created project directory. Existing project
        // directory events may be newly-created session transcripts.
        if isRoot { attachProjectDirectoryWatchers() }

        // Re-discover and attach any new top-level session files. Discovery keeps
        // the existing `/subagents/` exclusion, so this remains bounded.
        let files = ColdStartScanner.discoverJsonlFiles(under: rootURL)
        for file in files where sources[file] == nil {
            attachFile(file)
            handler(file) // trigger an initial parse
        }
    }

    private func fired(url: URL) {
        // Debounce: coalesce write bursts to one handler call per 250ms.
        debouncers[url]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.debouncers.removeValue(forKey: url)
            self.handler(url)
        }
        debouncers[url] = work
        queue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
