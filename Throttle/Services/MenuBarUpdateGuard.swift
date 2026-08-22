import Foundation
import os

/// Last-resort brake on a runaway menu-bar update loop.
///
/// Failure mode this exists for (observed 2026-08-19, 3.2.88): the `MenuBarExtra`
/// label was invalidated faster than SwiftUI could render it, so
/// `UpdateGroup.dispatchActions()` kept re-enqueuing `MenuBarExtraHost.requestUpdate(after:)`
/// and the main thread never returned to the run loop. Its autorelease pool
/// therefore never drained the `NSStatusItem._adjustLength` AutoLayout
/// temporaries: 276M live allocations and 42 GB of footprint in three minutes,
/// which swap-locked a 16 GB Mac hard enough that the Terminal stopped
/// responding. `MultiCockpitModel.waitingCount` is the real fix; this is the
/// net under it.
///
/// Two things this guard must do that nothing already in the app could:
///
/// 1. **Run off the main thread.** `MemoryPressureMonitor` uses a dispatch
///    source on `.main`, so during the wedge its handler never fired and quiet
///    mode / auto-hibernate never engaged. This watchdog owns a private queue.
/// 2. **Publish without a main-thread hop.** `isDegraded` is deliberately NOT
///    `@Observable`: an observable mutation would need the wedged main thread to
///    deliver it. During a runaway the label is re-rendering thousands of times
///    a second, so it reads the flag on its very next pass — no invalidation
///    needed.
enum MenuBarUpdateGuard {

    private static let log = Logger(subsystem: "com.lorislab.throttle", category: "menubar-guard")

    /// Footprint above which a fast climb is treated as a runaway. Normal
    /// Throttle with a full rail of hibernated tabs sits far below this.
    private static let softFloorBytes: UInt64 = 2 * 1024 * 1024 * 1024
    /// Growth within one sampling interval that no legitimate work produces.
    /// The observed runaway allocated ~160 MB/s (≈320 MB per interval).
    private static let softGrowthBytes: UInt64 = 200 * 1024 * 1024
    /// Consecutive breaching intervals before degrading. Loading the embedded
    /// model legitimately adds hundreds of MB in a few seconds, and that spike
    /// ENDS; the runaway does not. Requiring the breach to persist tells the two
    /// apart, at the cost of ~4 s of extra allocation in a real runaway — a
    /// price worth paying to never blank the menu bar on a healthy launch.
    private static let breachesToDegrade = 3
    /// Hard ceiling. Past this the main thread is already wedged and the soft
    /// degrade can no longer be picked up, so the only lever left is to stop
    /// taking the machine down. A dead menu-bar icon beats a Mac that needs a
    /// power cycle.
    private static let hardCeilingBytes: UInt64 = 8 * 1024 * 1024 * 1024
    private static let interval: DispatchTimeInterval = .seconds(2)

    private static let lock = OSAllocatedUnfairLock(initialState: false)
    private static let queue = DispatchQueue(label: "com.lorislab.throttle.menubar-guard",
                                             qos: .utility)
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    nonisolated(unsafe) private static var lastFootprint: UInt64 = 0
    nonisolated(unsafe) private static var consecutiveBreaches = 0

    /// Renders of `MenuBarLabel.body` since the last sample.
    ///
    /// Memory was the wrong and only signal. On 2026-08-21 the label spun at
    /// 100% of a core with a footprint of about 1 GB — `NSStatusBarButton
    /// setImage:` driving a full AutoLayout pass on the status item, over and
    /// over. The Mac was unusable and the guard never looked: its soft floor is
    /// 2 GB, so it was watching for a symptom this runaway had not produced yet.
    ///
    /// The loop's defining property is not its size, it is its RATE. A label
    /// that legitimately updates does so on a timer — a countdown moves once a
    /// minute, a percentage a few times a minute. Hundreds of renders in two
    /// seconds is not a fast update, it is a cycle.
    private static let renderCount = OSAllocatedUnfairLock(initialState: 0)

    /// Renders per sampling interval above which the label is a cycle, not a
    /// meter. Generous on purpose: at two seconds per sample this allows 30
    /// renders a second, far beyond anything a timer-driven label needs, so a
    /// busy-but-healthy period cannot trip it.
    private static let runawayRendersPerInterval = 60

    /// True while a runaway is in progress. `MenuBarLabel` renders a static icon
    /// in that case: no `Label`, no countdown, no width changes — nothing that
    /// can drive another `NSStatusItem._adjustLength` pass.
    ///
    /// Deliberately RECOVERABLE. A one-way latch would mean any single
    /// misjudgement costs the user their meter for the rest of the session, and
    /// the meter is the product — a guard that silently blanks it is worse than
    /// the bug it guards against whenever it is wrong.
    static var isDegraded: Bool { lock.withLock { $0 } }

    /// Start sampling. Called once from `AppDelegate`; safe to call twice.
    static func start() {
        queue.async {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + interval, repeating: interval)
            t.setEventHandler { sample() }
            t.resume()
            timer = t
        }
    }

    /// Called from `MenuBarLabel.body`. Cheap by construction: one lock, one
    /// increment, no allocation — it runs inside the render pass it measures.
    static func noteRender() {
        renderCount.withLock { $0 &+= 1 }
    }

    private static func sample() {
        let renders = renderCount.withLock { count -> Int in
            defer { count = 0 }
            return count
        }
        if renders >= runawayRendersPerInterval, !isDegraded {
            lock.withLock { $0 = true }
            log.fault("""
                menu-bar update runaway: \(renders, privacy: .public) renders in                 one interval — degrading the label to a static icon
                """)
        }

        guard let footprint = processFootprintBytes() else { return }
        defer { lastFootprint = footprint }

        if footprint >= hardCeilingBytes {
            log.fault("""
                menu-bar update runaway: footprint \(footprint / 1_048_576, privacy: .public) MB \
                past the hard ceiling — terminating instead of swap-locking the Mac
                """)
            // Give the log a moment to flush; the main thread cannot help here.
            queue.asyncAfter(deadline: .now() + 0.2) { exit(EXIT_FAILURE) }
            return
        }

        let grew = footprint > lastFootprint ? footprint - lastFootprint : 0
        let breaching = lastFootprint > 0
            && footprint >= softFloorBytes
            && grew >= softGrowthBytes

        guard breaching else {
            consecutiveBreaches = 0
            // Recover once the footprint is back under the floor: the runaway is
            // over (or was never one), and the live label can come back.
            if isDegraded, footprint < softFloorBytes, renders < runawayRendersPerInterval {
                lock.withLock { $0 = false }
                log.notice("""
                    menu-bar label restored: footprint back to \
                    \(footprint / 1_048_576, privacy: .public) MB
                    """)
            }
            return
        }

        consecutiveBreaches += 1
        guard !isDegraded, consecutiveBreaches >= breachesToDegrade else { return }

        lock.withLock { $0 = true }
        log.error("""
            menu-bar update runaway: footprint \(footprint / 1_048_576, privacy: .public) MB, \
            +\(grew / 1_048_576, privacy: .public) MB per interval for \
            \(consecutiveBreaches, privacy: .public) intervals — freezing the menu-bar label
            """)
    }

    /// Mach `phys_footprint` for this process — the same number Activity Monitor
    /// and `vmmap -summary` report, and the one that decides swap pressure.
    private static func processFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }
}
