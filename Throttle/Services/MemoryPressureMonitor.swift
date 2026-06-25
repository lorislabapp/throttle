import Foundation

/// macOS-native memory-pressure signal driving Throttle's "quiet mode": when the
/// kernel reports the system is swapping hard, Throttle backs off its own
/// background I/O so it stops amplifying the lag (the embedded terminal goes
/// unresponsive under pressure). Uses DISPATCH_SOURCE_TYPE_MEMORYPRESSURE — the
/// real signal, not a timer/guess. 100% automatic (NotebookLM design): the user
/// shouldn't hunt for a toggle while their terminal is frozen.
@MainActor @Observable
final class MemoryPressureMonitor {
    static let shared = MemoryPressureMonitor()

    enum Level: Int, Sendable { case normal = 0, warning = 1, critical = 2 }
    private(set) var level: Level = .normal

    /// True when Throttle should suppress non-vital background work.
    var isQuiet: Bool { level != .normal }

    private var source: DispatchSourceMemoryPressure?

    private init() {
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let event = src?.data else { return }
            // Kernel reports the current pressure level on each event.
            if event.contains(.critical) { self.level = .critical }
            else if event.contains(.warning) { self.level = .warning }
            else { self.level = .normal }
        }
        src.resume()
        self.source = src
    }
    // No deinit: the shared monitor lives for the whole app run.
}
