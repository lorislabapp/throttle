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
    /// Predictive nudge: warn when the current burn rate projects hitting the cap
    /// within this horizon — BEFORE the fixed 80/95 thresholds catch it.
    private let forecastHorizon: TimeInterval = 30 * 60
    private let forecastDebounce: TimeInterval = 2 * 3600
    private let forecastMinInterval: TimeInterval = 120   // need a ≥2-min baseline for a stable rate

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

    /// One window under threshold watch.
    ///
    /// `isScoped` marks the per-model cap STRUCTURALLY. It used to be recognised
    /// by comparing the label to the literal "Weekly Sonnet", so the moment the
    /// label started naming the model the server actually scoped the cap to, the
    /// softer "this is not a hard stop" wording silently stopped being used.
    private struct Metric {
        let label: String
        let pct: Double
        /// Seconds until reset; lets the forecast skip a window that resets
        /// before the current burn could ever reach the cap.
        let resetSec: Double
        let isScoped: Bool

        init(_ label: String, _ window: ExactSnapshot.Window, scoped: Bool) {
            self.label = label
            self.pct = Double(window.utilization) / 100.0
            self.resetSec = window.resetsAt?.timeIntervalSinceNow ?? -1
            self.isScoped = scoped
        }

        init(_ label: String, _ window: UsageSnapshot.Window, scoped: Bool) {
            self.label = label
            self.pct = window.percentUsed ?? 0
            self.resetSec = Double(window.resetInSeconds)
            self.isScoped = scoped
        }
    }

    /// Check the latest snapshot and fire notifications for any newly-crossed thresholds.
    /// Should be called from AppState.refresh() and after each ExactMode poll.
    func evaluate(snapshot: UsageSnapshot, exact: ExactSnapshot?) {
        guard enabled else { return }

        let metrics: [Metric] = {
            if let ex = exact, ex.isFresh() {
                let scopedName = ex.sevenDayScoped.scopedModel.map { "Weekly \($0)" }
                return [
                    Metric("Session 5h", ex.fiveHour, scoped: false),
                    Metric("Weekly all", ex.sevenDay, scoped: false),
                    Metric(scopedName ?? "Weekly (scoped)", ex.sevenDayScoped, scoped: true)
                ]
            }
            return [
                Metric("Session 5h", snapshot.session5h, scoped: false),
                Metric("Weekly all", snapshot.weeklyAll, scoped: false),
                Metric(ScopedCapModel.bindingLabel, snapshot.weeklySonnet, scoped: true)
            ]
        }()

        for metric in metrics {
            let (label, pct, isScoped) = (metric.label, metric.pct, metric.isScoped)
            for threshold in thresholds where pct >= threshold {
                let key = "lastFired_\(label)_\(Int(threshold * 100))"
                let lastFired = UserDefaults.standard.double(forKey: key)
                let now = Date().timeIntervalSince1970
                if now - lastFired < debounceInterval { continue }
                fire(label: label, percent: pct, threshold: threshold, isScoped: isScoped)
                UserDefaults.standard.set(now, forKey: key)
                // Only fire the highest crossed threshold per window per pass.
                break
            }
        }

        for metric in metrics {
            forecastCapETA(label: metric.label, pct: metric.pct,
                           resetSeconds: metric.resetSec, isScoped: metric.isScoped)
        }

        detectSessionReset(snapshot: snapshot, exact: exact)
    }

    /// Fire a "Session reset — break time?" notification when the rolling 5h
    /// window resets after non-trivial use. We detect a reset by watching for
    /// session5h utilization dropping from >40% to <8% between consecutive
    /// evaluations. Gated by debounceInterval so accidental drops don't spam.
    private func detectSessionReset(snapshot: UsageSnapshot, exact: ExactSnapshot?) {
        let pct: Double = {
            if let ex = exact, ex.isFresh() {
                return Double(ex.fiveHour.utilization) / 100.0
            }
            return snapshot.session5h.percentUsed ?? 0
        }()
        let lastPct = UserDefaults.standard.double(forKey: "lastSessionPct")
        UserDefaults.standard.set(pct, forKey: "lastSessionPct")

        guard lastPct > 0.40, pct < 0.08 else { return }

        let key = "lastFired_sessionReset"
        let lastFired = UserDefaults.standard.double(forKey: key)
        let now = Date().timeIntervalSince1970
        guard now - lastFired >= debounceInterval else { return }
        UserDefaults.standard.set(now, forKey: key)
        fireSessionReset()
    }

    private func fireSessionReset() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Your 5-hour session just reset")
        content.body = String(localized: "Fresh budget — good moment for a break, or attack a hard problem with full headroom.")
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "throttle.sessionReset.\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] err in
            if let err {
                self?.logger.error("Session-reset notification failed: \(err.localizedDescription)")
            }
        }
    }

    /// Predictive cap nudge — the moat. From the pct change since the last
    /// baseline (≥2 min ago) derive a burn rate, project ETA to 100%, and warn
    /// if the cap is within `forecastHorizon` AND the window won't reset first.
    /// Only in the mid-range (50–95%); below is premature, ≥95% the fixed
    /// threshold already fires. Pure derivation from pct — no DB, no burn query.
    private func forecastCapETA(label: String, pct: Double, resetSeconds: Double, isScoped: Bool) {
        let pKey = "fcPct_\(label)", tKey = "fcT_\(label)", fKey = "fcFired_\(label)"
        // Outside the actionable band: clear the baseline so a fresh rise starts clean.
        guard pct >= 0.50, pct < 0.95 else {
            UserDefaults.standard.removeObject(forKey: pKey)
            UserDefaults.standard.removeObject(forKey: tKey)
            return
        }
        let now = Date().timeIntervalSince1970
        let lastT = UserDefaults.standard.double(forKey: tKey)
        let lastPct = UserDefaults.standard.double(forKey: pKey)
        // No baseline yet, or it's too fresh to give a stable rate → keep waiting
        // (don't move the anchor until it's old enough).
        guard lastT > 0 else {
            UserDefaults.standard.set(now, forKey: tKey); UserDefaults.standard.set(pct, forKey: pKey); return
        }
        let dt = now - lastT
        guard dt >= forecastMinInterval else { return }
        // Re-anchor for the next interval.
        UserDefaults.standard.set(now, forKey: tKey); UserDefaults.standard.set(pct, forKey: pKey)

        let dpct = pct - lastPct
        guard dpct > 0 else { return }                       // not rising → no ETA
        let etaSec = (1.0 - pct) / (dpct / dt)
        guard etaSec <= forecastHorizon else { return }      // not imminent
        if resetSeconds > 0, resetSeconds <= etaSec { return } // resets before cap → safe

        let lastFired = UserDefaults.standard.double(forKey: fKey)
        guard now - lastFired >= forecastDebounce else { return }
        UserDefaults.standard.set(now, forKey: fKey)
        fireForecast(label: label, etaMinutes: max(1, Int(etaSec / 60)), pct: Int(pct * 100), isScoped: isScoped)
    }

    private func fireForecast(label: String, etaMinutes: Int, pct: Int, isScoped: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "\(label) cap in ~\(etaMinutes) min"
        content.body = isScoped
            ? "At your current rate the \(label) cap is ~\(etaMinutes) min away "
              + "(\(pct)% now) — switch to another model to keep going."
            : "At your current burn rate you'll hit the \(label) cap in ~\(etaMinutes) min "
              + "(\(pct)% now). Wrap up or batch to avoid a lockout."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "throttle.forecast.\(label)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] err in
            if let err { self?.logger.error("Forecast notification failed: \(err.localizedDescription)") }
        }
    }

    private func fire(label: String, percent: Double, threshold: Double, isScoped: Bool) {
        let content = UNMutableNotificationContent()
        let pctInt = Int(percent * 100)
        let thrInt = Int(threshold * 100)
        content.title = "Claude usage at \(pctInt)%"
        // The per-model weekly cap isn't a hard stop — when it's exhausted you
        // can still work on another model. Frame it as a fallback prompt, not a
        // "slow down" warning, so users don't sit out thinking they're locked.
        // It does NOT name the model to switch TO: the cap is not always
        // Sonnet's, and telling someone capped on Opus to "switch to Opus" is
        // the same defect one layer down.
        if isScoped {
            content.body = "\(label) at \(pctInt)% — switch to another model to keep working."
        } else {
            content.body = "\(label) crossed \(thrInt)% — slow down or batch your work."
        }
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
