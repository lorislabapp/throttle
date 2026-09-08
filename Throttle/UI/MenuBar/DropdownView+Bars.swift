import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

extension DropdownView {
    struct UsageBar: View {
        let pct: Double?
        let tint: Color
        var degraded: Bool = false
        var height: CGFloat = 6
        var strongTicks: Bool = false

        var body: some View {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    ForEach([0.80, 0.95], id: \.self) { mark in
                        Rectangle()
                            .fill(Color.primary.opacity(strongTicks ? 0.22 : 0.15))
                            .frame(width: strongTicks ? 1.5 : 1, height: height)
                            .offset(x: w * mark)
                    }
                    if let p = pct {
                        let fillW = max(height, min(w, w * p))
                        Group {
                            if degraded {
                                Stripes().stroke(tint.opacity(0.85), lineWidth: 1.5)
                            } else {
                                Capsule().fill(tint)
                            }
                        }
                        .frame(width: fillW)
                        .clipShape(Capsule())
                    }
                }
            }
            .frame(height: height)
        }
    }

    /// Diagonal hatch for the estimate (degraded) fill.
    struct Stripes: Shape {
        var spacing: CGFloat = 4
        func path(in rect: CGRect) -> Path {
            var p = Path()
            var x = -rect.height
            while x < rect.width + rect.height {
                p.move(to: CGPoint(x: x, y: rect.height))
                p.addLine(to: CGPoint(x: x + rect.height, y: 0))
                x += spacing
            }
            return p
        }
    }

    /// Wall-clock time this many seconds from now (e.g. "9pm", "Mon 4pm").
    /// Matches claude.ai's "resets 9pm (Europe/Paris)" framing so users
    /// don't have to mentally add countdown to current time.
    func formatWallClock(_ secondsFromNow: Int64) -> String {
        let target = Date().addingTimeInterval(TimeInterval(secondsFromNow))
        let cal = Calendar.current
        let now = Date()
        let f = DateFormatter()
        f.locale = .current
        let isToday = cal.isDateInToday(target)
        let isTomorrow = cal.isDateInTomorrow(target)
        let withinThreeDays = (target.timeIntervalSince(now)) < 3 * 24 * 3600
        // Include minutes only when the reset isn't on the hour. Anthropic's
        // weekly windows usually reset on the hour ("4pm"), but the session
        // window and API-supplied resets_at can land mid-hour (15:59) — the
        // old hour-only "ha" template floored that to "3pm", which reads as
        // an hour in the past when the countdown says "in 3m".
        let hourTok = cal.component(.minute, from: target) != 0 ? "hmm" : "h"
        if isToday {
            f.setLocalizedDateFormatFromTemplate("\(hourTok)a")
            return f.string(from: target).lowercased()
        }
        if isTomorrow {
            f.setLocalizedDateFormatFromTemplate("\(hourTok)a")
            return "tmrw \(f.string(from: target).lowercased())"
        }
        if withinThreeDays {
            f.setLocalizedDateFormatFromTemplate("EEE\(hourTok)a")
            return f.string(from: target).lowercased()
        }
        f.setLocalizedDateFormatFromTemplate("EEEMMMd\(hourTok)a")
        return f.string(from: target).lowercased()
    }

    /// A row is "degraded" — shown muted with an ≈/estimate tag — when the
    /// user enabled exact mode but this window is falling back to local
    /// JSONL math. That's the case the meter must not dress up as confident:
    /// a local 90% that won't track the server cap. Pure-local users (exact
    /// never enabled) keep the clean display — local-by-design isn't a
    /// degradation, and tagging all three rows would just be noise.
    func degraded(_ metric: DisplayMetric) -> Bool {
        appState.exactModeEnabled && !metric.isExact
    }

    /// The BAR fill colour — neutral graphite until pressure is real. Colour is
    /// earned, not default: accent blue never touches the bars.
    func progressTint(for pct: Double) -> Color {
        switch pct {
        case ..<0.8:  return Color.primary.opacity(0.45)
        case ..<0.95: return .orange
        default:      return .red
        }
    }

    /// The NUMBER colour — primary ink until pressure, muted when degraded.
    func numberColor(pct: Double, degraded deg: Bool) -> Color {
        if deg { return .secondary }
        switch pct {
        case ..<0.8:  return .primary
        case ..<0.95: return .orange
        default:      return .red
        }
    }

    /// Direction A — "The Dock". Four destinations as a compact icon row over
    /// one quiet meta line carrying sign-in STATUS and demoted chrome. Replaces
    /// the old flat 10-row menu (incl. the two inert Run Optimizer / Manage
    /// Hooks rows, which did nothing and duplicated Settings/Project). Pro/Free
    /// already lives in the title pill, so the footer stays pure navigation and
    /// subordinate to the meter above.
}
