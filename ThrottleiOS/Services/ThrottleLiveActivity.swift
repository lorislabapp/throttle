#if os(iOS)
import ActivityKit
import OSLog
import ThrottleShared
import UIKit

/// Owns the single Claude-usage Live Activity: starts it (foreground only, per
/// ActivityKit rules), keeps it in step with every mirror snapshot, and ends it.
///
/// Driven from `MirrorStore.ingest`, so the Dynamic Island / lock-screen banner
/// tracks the same data as the app and the widget. A running activity can be
/// UPDATED from the background (e.g. a CloudKit push waking the app), but iOS only
/// lets us START one while the app is active — `sync` respects that.
@MainActor
enum ThrottleLiveActivity {
    static let enabledKey = "throttleLiveActivityEnabled"
    private static let log = Logger(subsystem: "com.lorislab.throttle.ios", category: "LiveActivity")
    private static let operations = LiveActivityOperationQueue()

    static var isEnabled: Bool {
        !CompanionRuntime.isTesting && CompanionRuntime.defaults.bool(forKey: enabledKey)
    }

    private static func state(from snap: ThrottleMirrorSnapshot) -> ThrottleActivityAttributes.ContentState {
        let b = snap.bindingWindow
        return .init(fiveHour: snap.fiveHour.utilization,
                     sevenDay: snap.sevenDay.utilization,
                     binding: b.utilization,
                     bindingResetsAt: b.resetsAt)
    }

    /// Keep it stale-marked a little past the reset (or 30 min out) so iOS dims a
    /// stale banner rather than showing a frozen number if updates stop.
    private static func staleDate(_ snap: ThrottleMirrorSnapshot) -> Date {
        let reset = snap.bindingWindow.resetsAt ?? Date().addingTimeInterval(1800)
        return max(reset, Date().addingTimeInterval(600))
    }

    /// Single entry point, called on every new snapshot. Reconciles the live
    /// activity to the current setting + data.
    static func sync(_ snap: ThrottleMirrorSnapshot) {
        guard !CompanionRuntime.isTesting else { return }
        operations.supersedeUpdates()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let running = Activity<ThrottleActivityAttributes>.activities.first {
            !operations.isRetiring($0.id)
        }

        guard isEnabled else { if running != nil { end() }; return }

        let content = ActivityContent(state: state(from: snap), staleDate: staleDate(snap))
        if let activityID = running?.id {
            operations.update(id: activityID) {
                await updateActivity(id: activityID, content: content)
            }
        } else if UIApplication.shared.applicationState == .active {
            // Foreground-only start (ActivityKit requirement).
            do {
                _ = try Activity.request(
                    attributes: ThrottleActivityAttributes(deviceName: snap.deviceName),
                    content: content, pushType: nil)
            } catch {
                log.info("Live Activity start failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // else: enabled but no activity and app backgrounded — can't start now;
        // the next foreground snapshot will.
    }

    /// Turn the feature on/off from Settings. Turning on starts immediately from the
    /// latest snapshot (Settings is foreground); turning off ends the activity.
    static func setEnabled(_ on: Bool) {
        CompanionRuntime.defaults.set(on, forKey: enabledKey)
        if on {
            if let snap = MirrorStore.shared.latest { sync(snap) }
        } else {
            end()
        }
    }

    static func end() {
        guard !CompanionRuntime.isTesting else { return }
        // Revoke the old IDs immediately. Cleanup follows any update already in
        // flight, and cannot target an activity created for the next account.
        let oldIDs = Set(Activity<ThrottleActivityAttributes>.activities.map(\.id))
        operations.retire(ids: oldIDs) { ids in
            await endActivities(ids: ids)
        }
    }

    // ActivityKit's Activity is not Sendable and its async methods are
    // nonisolated. Keep every Activity reference local to these nonisolated
    // operations; only IDs and Sendable content cross the MainActor boundary.
    nonisolated private static func updateActivity(
        id: String, content: ActivityContent<ThrottleActivityAttributes.ContentState>
    ) async {
        guard let activity = Activity<ThrottleActivityAttributes>.activities.first(where: { $0.id == id }) else {
            return
        }
        await activity.update(content)
    }

    nonisolated private static func endActivities(ids: Set<String>) async {
        for id in ids {
            guard let activity = Activity<ThrottleActivityAttributes>.activities.first(where: { $0.id == id }) else {
                continue
            }
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#endif

/// Orders asynchronous ActivityKit writes while revocation remains synchronous.
/// In particular, an account scrub cannot be overtaken by an in-flight update.
@MainActor
final class LiveActivityOperationQueue {
    private var generation: UInt64 = 0
    private var retiringIDs: Set<String> = []
    private(set) var pendingTask: Task<Void, Never>?

    func supersedeUpdates() {
        generation &+= 1
    }

    func isRetiring(_ id: String) -> Bool {
        retiringIDs.contains(id)
    }

    func update(id: String, operation: @escaping @Sendable () async -> Void) {
        let token = generation
        let previous = pendingTask
        pendingTask = Task { @MainActor in
            await previous?.value
            guard self.generation == token, !self.isRetiring(id) else { return }
            await operation()
        }
    }

    func retire(ids: Set<String>, operation: @escaping @Sendable (Set<String>) async -> Void) {
        supersedeUpdates()
        retiringIDs.formUnion(ids)
        let previous = pendingTask
        pendingTask = Task { @MainActor in
            await previous?.value
            await operation(ids)
        }
    }
}
