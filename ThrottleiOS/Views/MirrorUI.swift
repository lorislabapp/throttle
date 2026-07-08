import SwiftUI
import ThrottleShared

/// Shared presentation helpers so every screen + the widget agree on colors,
/// glyphs, and formatting.
enum MirrorUI {
    static let accent = Color(red: 0.0, green: 0.443, blue: 0.890)   // #0071E3

    /// Meter color by utilization, matching the Mac widget's 80/95 thresholds.
    static func color(forUtilization pct: Int) -> Color {
        switch pct {
        case 95...: return .red
        case 80..<95: return .orange
        default: return accent
        }
    }

    static func stateColor(_ s: SessionStateMirror?) -> Color {
        switch s {
        case .working:     return .green
        case .waiting:     return .orange
        case .rateLimited: return .red
        case .paused:      return .yellow
        case .idle:        return .secondary
        case .hibernated, .dormant, .none: return Color.secondary.opacity(0.5)
        }
    }

    static func stateGlyph(_ s: SessionStateMirror?) -> String {
        switch s {
        case .working:     return "bolt.fill"
        case .waiting:     return "questionmark.circle.fill"
        case .rateLimited: return "exclamationmark.triangle.fill"
        case .paused:      return "pause.circle.fill"
        case .idle:        return "circle"
        case .hibernated:  return "moon.zzz.fill"
        case .dormant, .none: return "circle.dotted"
        }
    }

    /// "resets in 2h 14m" for an absolute future date, or nil if none/past.
    static func countdown(to date: Date?, now: Date = Date()) -> String? {
        guard let date, date > now else { return nil }
        let s = Int(date.timeIntervalSince(now))
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = Int(max(0, now.timeIntervalSince(date)))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    static func compactTokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.0fk", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }
}
