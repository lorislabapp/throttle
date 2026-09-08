import AppKit
import SwiftTerm
import SwiftUI

extension MultiCockpitModel {

    /// Drag-reorder: move `dragged` to where `target` sits. Persists the order.
    /// Label the per-model weekly cap with the model Anthropic actually scoped it
    /// to. It used to say "Sonnet" unconditionally: measured 2026-08-22, the cap
    /// at 100% was scoped to Fable, and the loudest number in the app named the
    /// wrong model. The name is in the payload; the only reason it was ever
    /// wrong is that it was thrown away.
    static func scopedLabel(_ w: ExactSnapshot.Window) -> String {
        w.scopedModel.map { "Weekly · \($0)" } ?? "Weekly · scoped"
    }

    /// The local/mirrored shape carries no model name of its own, so it uses the
    /// last name the server stated on this Mac. That is a fact we were told, not
    /// a guess — and the guess is exactly what was wrong.
    static var scopedLabelMirror: String { ScopedCapModel.bindingLabel }

    // MARK: - Global binding (account-wide, shared by all sessions)

    struct Binding { let pct: Int; let name: String; let reset: String; let estimate: Bool; let resetInSeconds: Int64? }

    /// "2h 14m" style countdown for the binding reset.
    static func countdown(_ seconds: Int64) -> String {
        guard seconds > 0 else { return "now" }
        let h = seconds / 3600, m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    var binding: Binding? {
        guard let appState else { return nil }
        var candidates: [Binding] = []
        // Only claim EXACT when the server snapshot is actually fresh — otherwise
        // degrade to the local estimate (≈), same as the menu-bar dropdown. A
        // stale exact value labelled EXACT violates the golden rule.
        if let ex = appState.exactSnapshot, ex.isFresh() {
            let ws: [(String, Int, Date?)] = [
                ("Session", ex.fiveHour.utilization, ex.fiveHour.resetsAt),
                ("Weekly", ex.sevenDay.utilization, ex.sevenDay.resetsAt),
                (Self.scopedLabel(ex.sevenDayScoped), ex.sevenDayScoped.utilization, ex.sevenDaySonnet.resetsAt)
            ]
            for window in ws {
                candidates.append(Binding(
                    pct: window.1,
                    name: "Claude · \(window.0)",
                    reset: window.2.map(Self.hm) ?? "—",
                    estimate: false,
                    resetInSeconds: window.2.map { Int64($0.timeIntervalSinceNow) }
                ))
            }
        } else {
            let snap = appState.snapshot
            let local: [(String, Double, Int64)] = [
                ("Session", snap.session5h.percentUsed ?? -1, snap.session5h.resetInSeconds),
                ("Weekly", snap.weeklyAll.percentUsed ?? -1, snap.weeklyAll.resetInSeconds),
                (Self.scopedLabelMirror, snap.weeklySonnet.percentUsed ?? -1, snap.weeklySonnet.resetInSeconds)
            ].filter { $0.1 >= 0 }
            candidates.append(contentsOf: local.map { value in
                Binding(
                    pct: Int((value.1 * 100).rounded()),
                    name: "Claude · \(value.0)",
                    reset: Self.hm(Date().addingTimeInterval(TimeInterval(value.2))),
                    estimate: true,
                    resetInSeconds: value.2
                )
            })
        }
        if let codex = appState.codexUsageSnapshot, codex.isFresh() {
            candidates.append(contentsOf: codex.windows.map { window in
                let minutes = window.windowMinutes.map { String($0) } ?? "?"
                let label = window.windowMinutes == 300 ? "5h"
                    : (window.windowMinutes == 10_080 ? "Weekly" : "\(minutes)m")
                return Binding(
                    pct: Int(window.usedPercent.rounded()),
                    name: "Codex · \(label)",
                    reset: window.resetsAt.map(Self.hm) ?? "—",
                    estimate: false,
                    resetInSeconds: window.resetsAt.map { Int64($0.timeIntervalSinceNow) }
                )
            })
        }
        return candidates.max(by: { $0.pct < $1.pct })
    }
    static func hm(_ d: Date) -> String {
        return hmFormatter.string(from: d)
    }
}
