import Foundation
import OSLog

/// Watches a directory tree for `.jsonl` writes. On any event, calls the handler
/// with the URL that changed. Coalesces bursts via a 250ms debounce per path.
///
/// @unchecked Sendable: All mutable state (`sources`, `fds`, `debouncers`)
/// is confined to the serial `queue`. Every mutation runs via `queue.async`,
/// so concurrent access is structurally impossible.
final class LiveFileWatcher: @unchecked Sendable {
    private let rootURL: URL
    private let handler: @Sendable (URL) -> Void
    private let logger = Logger(subsystem: "com.lorislab.throttle", category: "LiveFileWatcher")

    private let queue = DispatchQueue(label: "com.lorislab.throttle.watcher", qos: .utility)
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var fds: [URL: Int32] = [:]
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
            self.attachDirectoryWatcher()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.isRunning = false
            for src in self.sources.values { src.cancel() }
            for fd in self.fds.values { close(fd) }
            self.sources.removeAll()
            self.fds.removeAll()
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
        fds[url] = fd
        src.resume()
    }

    private func attachDirectoryWatcher() {
        guard isRunning else { return }
        let fd = open(rootURL.path, O_EVTONLY)
        guard fd >= 0 else {
            logger.warning("Failed to open root \(self.rootURL.path, privacy: .public) for watching")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.directoryChanged()
        }
        src.setCancelHandler { close(fd) }
        sources[rootURL] = src
        fds[rootURL] = fd
        src.resume()
    }

    private func directoryChanged() {
        // Check if root directory still exists (might have been deleted)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else {
            logger.warning("Root directory \(self.rootURL.path, privacy: .public) no longer exists, stopping watcher")
            stop()
            return
        }

        // New session files may have appeared. Re-discover and attach any new ones.
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
            self?.handler(url)
        }
        debouncers[url] = work
        queue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
