import Foundation
import OSLog
import UserNotifications

/// Fires UN notifications when a window crosses 80% or 95% utilization.
/// Per-window per-threshold debouncing prevents spam — same threshold
/// fires at most once per `debounceInterval` (default 6h).
///
/// Authorization is requested lazily on first opt-in; if the user denies,
/// the notifier is a no-op.
@MainActor
final class ThresholdNotifier {
    static let shared = ThresholdNotifier()

    private let logger = Logger(subsystem: "com.lorislab.throttle", category: "ThresholdNotifier")
    private let debounceInterval: TimeInterval = 6 * 3600
    private let thresholds: [Double] = [0.80, 0.95]

    private var enabled: Bool {
        UserDefaults.standard.bool(forKey: "thresholdNotificationsEnabled")
    }

    func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "thresholdNotificationsEnabled")
        if value {
            requestAuthorizationIfNeeded()
        }
    }

    var isEnabled: Bool { enabled }

    /// Check the latest snapshot and fire notifications for any newly-crossed thresholds.
    /// Should be called from AppState.refresh() and after each ExactMode poll.
    func evaluate(snapshot: UsageSnapshot, exact: ExactSnapshot?) {
        guard enabled else { return }

        let metrics: [(String, Double)] = {
            if let ex = exact, ex.isFresh() {
                return [
                    ("Session 5h",    Double(ex.fiveHour.utilization) / 100.0),
                    ("Weekly all",    Double(ex.sevenDay.utilization) / 100.0),
                    ("Weekly Sonnet", Double(ex.sevenDaySonnet.utilization) / 100.0)
                ]
            }
            return [
                ("Session 5h",    snapshot.session5h.percentUsed ?? 0),
                ("Weekly all",    snapshot.weeklyAll.percentUsed ?? 0),
                ("Weekly Sonnet", snapshot.weeklySonnet.percentUsed ?? 0)
            ]
        }()

        for (label, pct) in metrics {
            for threshold in thresholds where pct >= threshold {
                let key = "lastFired_\(label)_\(Int(threshold * 100))"
                let lastFired = UserDefaults.standard.double(forKey: key)
                let now = Date().timeIntervalSince1970
                if now - lastFired < debounceInterval { continue }
                fire(label: label, percent: pct, threshold: threshold)
                UserDefaults.standard.set(now, forKey: key)
                // Only fire the highest crossed threshold per window per pass.
                break
            }
        }
    }

    private func fire(label: String, percent: Double, threshold: Double) {
        let content = UNMutableNotificationContent()
        let pctInt = Int(percent * 100)
        let thrInt = Int(threshold * 100)
        content.title = "Claude usage at \(pctInt)%"
        content.body = "\(label) crossed \(thrInt)% — slow down or batch your work."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "throttle.threshold.\(label).\(thrInt)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] err in
            if let err {
                self?.logger.error("Notification add failed: \(err.localizedDescription)")
            }
        }
    }

    private func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, err in
                    if let err {
                        self.logger.error("Notification authorization failed: \(err.localizedDescription)")
                    } else {
                        self.logger.info("Notification authorization: \(granted)")
                    }
                }
            case .denied:
                self.logger.notice("Notifications denied — user must enable in System Settings.")
            default:
                break
            }
        }
    }
}
