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

    /// User/Focus-driven override (an App Intent or a Deep-Work Focus Filter). ORs
    /// with the kernel signal — quiet mode is on if EITHER the system is under
    /// pressure OR the user asked for it. NotebookLM design: a manual override on
    /// top of the automatic memory-pressure signal.
    var manualQuietOverride = false

    /// True when Throttle should suppress non-vital background work.
    var isQuiet: Bool { level != .normal || manualQuietOverride }

    private var source: DispatchSourceMemoryPressure?

    /// Reclaimers that RELEASE memory when pressure RISES to a higher level
    /// (e.g. auto-hibernate idle sessions on `.critical`). This complements
    /// `isQuiet`, which only makes callers SKIP new work — nothing here freed
    /// already-held RAM before. Fired only on an increase, on the main actor.
    private var onRise: [(Level) -> Void] = []
    func onPressureRise(_ cb: @escaping (Level) -> Void) { onRise.append(cb) }

    private init() {
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let event = src?.data else { return }
            let old = self.level
            // Kernel reports the current pressure level on each event.
            if event.contains(.critical) { self.level = .critical }
            else if event.contains(.warning) { self.level = .warning }
            else { self.level = .normal }
            // Fire reclaimers only when pressure actually worsened.
            if self.level.rawValue > old.rawValue {
                for cb in self.onRise { cb(self.level) }
            }
        }
        src.resume()
        self.source = src
    }
    // No deinit: the shared monitor lives for the whole app run.
}
