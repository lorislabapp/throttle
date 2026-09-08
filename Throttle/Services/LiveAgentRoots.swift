import Foundation
import os

/// The root PIDs of every live cockpit session, readable from any thread.
///
/// ## Why this exists
///
/// `MenuBarUpdateGuard` kills the app from a background queue when the footprint
/// passes the hard ceiling — the last defence against swap-locking a 16 GB Mac.
/// It called `exit(EXIT_FAILURE)`, which does **not** run
/// `applicationWillTerminate`, so `MultiCockpitModel.stop()` — the only thing
/// that hard-kills each session's process subtree — never fired. Every `claude`
/// and `node` under those shells reparented to launchd and **kept its RAM**,
/// with no UI left to reclaim them. A guard whose job is preventing a swap-lock
/// could leave fifty orphans holding several GB behind.
///
/// The sessions live on `@MainActor` and the guard cannot touch them, so the
/// PIDs are mirrored here behind a lock. Registration is cheap and happens only
/// on spawn and termination.
enum LiveAgentRoots {

    private static let lock = OSAllocatedUnfairLock(initialState: [Int32: NativeProcessIdentity]())

    static func register(_ identity: NativeProcessIdentity) {
        lock.withLock { $0[identity.pid] = identity }
    }

    static func unregister(_ pid: Int32) {
        lock.withLock { _ = $0.removeValue(forKey: pid) }
    }

    static var current: [Int32] {
        lock.withLock { Array($0.keys) }
    }

    /// Terminate every registered subtree. Safe to call from any thread, and
    /// deliberately best-effort: this runs on the way out, and a PID that has
    /// already gone is not an error.
    ///
    /// Allow a short TERM grace, then escalate only the captured owned scope.
    /// This emergency path cannot offer the interactive recovery used by quit.
    static func terminateAll() {
        let roots = lock.withLock { Array($0.values) }
        for root in roots {
            if let scope = OwnedProcessTermination.capture(roots: [root]) {
                _ = OwnedProcessTermination.stop(scope, grace: 0.2, exitTimeout: 0.2)
            }
        }
    }
}
