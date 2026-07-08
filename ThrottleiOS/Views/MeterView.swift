import SwiftUI
import ThrottleShared

/// The hero ring: a big utilization gauge with the percent in the center and an
/// optional cap-countdown subtitle. Precise-cockpit look — thin ring, monospace number.
struct MeterView: View {
    let window: WindowMirror
    let label: String
    var now: Date = Date()

    private var fraction: Double { min(1, Double(window.utilization) / 100) }
    private var color: Color { MirrorUI.color(forUtilization: window.utilization) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: 14)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: fraction)
            centerLabel
        }
        .frame(width: 220, height: 220)
    }

    private var centerLabel: some View {
        VStack(spacing: 2) {
            Text("\(window.utilization)")
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label.uppercased())
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .tracking(1.5)
            if let cd = MirrorUI.countdown(to: window.resetsAt, now: now) {
                Text("resets in \(cd)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Small linear bar used for the secondary windows under the hero ring.
struct WindowBar: View {
    let window: WindowMirror
    let label: String
    var now: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(window.utilization)%")
                    .font(.subheadline).monospacedDigit()
                    .foregroundStyle(MirrorUI.color(forUtilization: window.utilization))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(MirrorUI.color(forUtilization: window.utilization))
                        .frame(width: geo.size.width * min(1, Double(window.utilization) / 100))
                }
            }
            .frame(height: 6)
            if let cd = MirrorUI.countdown(to: window.resetsAt, now: now) {
                Text("resets in \(cd)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
