import Foundation
import OSLog

/// Watches one project's `.throttle/` directory so the UI reflects an agent's
/// progress without polling.
///
/// Deliberately a separate type from `LiveFileWatcher`, which is hard-wired to
/// Claude Code's `.jsonl` transcripts and sits on the metering hot path. Sharing
/// it would mean editing the code that decides whether the user's usage numbers
/// are right, to serve a feature that can afford to miss a beat.
///
/// @unchecked Sendable: every mutable field is confined to `queue`, and every
/// mutation runs through `queue.async`.
final class PlanWatcher: @unchecked Sendable {

    private let root: URL
    private let onChange: @Sendable () -> Void
    private let logger = Logger(subsystem: "com.lorislab.throttle", category: "PlanWatcher")

    private let queue = DispatchQueue(label: "com.lorislab.throttle.planwatcher", qos: .utility)
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var debounce: DispatchWorkItem?
    private var isRunning = false

    /// Agents append in bursts — a claim, three progress lines and an evidence
    /// line can land inside one turn. Coalescing means one replay, not five.
    private let debounceInterval: DispatchTimeInterval = .milliseconds(250)

    init(projectRoot: URL, onChange: @escaping @Sendable () -> Void) {
        self.root = projectRoot
        self.onChange = onChange
    }

    deinit { sources.values.forEach { $0.cancel() } }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            let dir = self.root.appendingPathComponent(".throttle", isDirectory: true)
            // Watching the directories rather than each log file means a task that
            // gets its first event is picked up without a rescan.
            self.watch(dir)
            self.watch(dir.appendingPathComponent("log", isDirectory: true))
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.sources.values.forEach { $0.cancel() }
            self.sources.removeAll()
            self.debounce?.cancel()
            self.debounce = nil
        }
    }

    private func watch(_ url: URL) {
        guard isRunning, sources[url] == nil else { return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // A project with no plan yet is the normal case, not an error.
            logger.debug("No directory to watch at \(url.lastPathComponent, privacy: .public)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(descriptor) }
        sources[url] = source
        source.resume()
    }

    private func schedule() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.onChange()
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
