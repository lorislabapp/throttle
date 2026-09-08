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
    private static var generation: UInt64 = 0

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
        generation &+= 1
        let token = generation
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let running = Activity<ThrottleActivityAttributes>.activities.first

        guard isEnabled else { if running != nil { end() }; return }

        let content = ActivityContent(state: state(from: snap), staleDate: staleDate(snap))
        if let activityID = running?.id {
            // Re-fetch inside the task rather than capturing the Activity across the
            // isolation boundary (Swift 6 sending rule). `content` is Sendable.
            Task { @MainActor in
                guard generation == token else { return }
                let activities = Activity<ThrottleActivityAttributes>.activities
                guard let activity = activities.first(where: { $0.id == activityID }) else { return }
                await activity.update(content)
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
        generation &+= 1
        // Capture only the old activities. Delayed cleanup must not end an activity
        // created for the next account while ActivityKit is processing this one.
        let oldActivities = Activity<ThrottleActivityAttributes>.activities
        Task { @MainActor in
            for activity in oldActivities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
#endif
