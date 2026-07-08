import Foundation
import CloudKit
import ThrottleShared

/// Publishes the live usage/cockpit mirror to the user's **private** CloudKit
/// database so the Throttle iOS companion can mirror it anywhere (LAN or
/// cellular), with zero LorisLabs server in the path.
///
/// Doctrine: this is measure-only. It *reads* current state and writes a small
/// read-only snapshot to the user's own iCloud — it never rewrites anything on
/// the Mac. Fail-open like `TraycerReceiver`: if iCloud is signed out or the
/// entitlement is missing, it silently disables and the meter is unaffected.
///
/// Opt-in: started from `AppDelegate` only when `throttleiCloudMirrorEnabled`.
/// Single writer per device (fixed record name) → force-overwrite, no conflicts.
/// Debounced to ≤1 write / 25 s (integer-percent changes below that are noise
/// and CloudKit throttles aggressive writers).
@MainActor
final class CloudKitPublisher {
    static let shared = CloudKitPublisher()
    private init() {}

    private var database: CKDatabase?
    private var enabled = false
    private var pending: ThrottleMirrorSnapshot?
    private var flushScheduled = false
    private var lastSentAt = Date.distantPast
    private var lastRecord: CKRecord?
    private let minInterval: TimeInterval = 25

    /// Resolve the container + verify the iCloud account, then arm publishing.
    func start() {
        let container = CKContainer(identifier: CloudKitSchema.containerID)
        let db = container.privateCloudDatabase
        Task { [weak self] in
            let status = try? await container.accountStatus()
            guard status == .available else {
                NSLog("[CloudKitPublisher] iCloud unavailable (\(String(describing: status))) — mirror disabled")
                return
            }
            self?.database = db
            self?.enabled = true
            // Flush anything queued before the account check finished.
            if self?.pending != nil { self?.scheduleFlush() }
        }
    }

    func stop() {
        enabled = false
        pending = nil
        flushScheduled = false
    }

    /// Queue the latest snapshot for publishing. Cheap — safe to call on every
    /// `AppState.refresh()`; the debounce coalesces bursts.
    func publish(_ snap: ThrottleMirrorSnapshot) {
        pending = snap                 // always hold the freshest
        guard enabled else { return }  // will flush once start() arms us
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard enabled, !flushScheduled else { return }
        flushScheduled = true
        let wait = max(0, minInterval - Date().timeIntervalSince(lastSentAt))
        Task { [weak self] in
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            await self?.flush()
        }
    }

    private func flush() async {
        flushScheduled = false
        guard enabled, let db = database, let snap = pending else { return }
        pending = nil
        do {
            let record = try CloudKitRecordMapping.record(from: snap, existing: lastRecord)
            // .allKeys = force overwrite ignoring the server change tag. Correct
            // for a single-writer-per-device record: this Mac is the only author.
            let (saveResults, _) = try await db.modifyRecords(
                saving: [record], deleting: [], savePolicy: .allKeys, atomically: true)
            if case .success(let saved)? = saveResults[record.recordID] {
                lastRecord = saved
            }
            lastSentAt = Date()
        } catch {
            // Transient/network — the next state change supersedes this one.
            NSLog("[CloudKitPublisher] publish failed (retries on next change): \(error.localizedDescription)")
        }
    }
}
