import SwiftUI

/// The cockpit window: a live usage strip pinned above a real terminal running
/// `claude`. The terminal is just the container; the differentiator is the
/// decision layer on top (the binding number + pressure) — the thing
/// Anthropic's own usage dashboard does not surface.
struct CockpitWindowRoot: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            meterStrip
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
            CockpitTerminalView()
                .background(Color(nsColor: .textBackgroundColor))
        }
    }

    // MARK: - Pinned meter strip (reuses the cockpit language)

    private var meterStrip: some View {
        HStack(spacing: 14) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 14)).foregroundStyle(.primary.opacity(0.85))
            Text("Throttle").font(.system(size: 13, weight: .semibold))
            if appState.exactSnapshot?.isFresh() == true {
                HStack(spacing: 4) {
                    Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 4, height: 4)
                    Text("EXACT")
                }
                .font(.system(size: 9, weight: .heavy))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.primary, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            }
            Spacer(minLength: 12)
            windowReadout("5h", session5hPct)
            windowReadout("7d", weeklyAllPct)
            windowReadout("Son", weeklySonnetPct)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func windowReadout(_ label: String, _ pct: Double?) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            if let pct {
                Text("\(Int(pct * 100))%")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(pressureColor(pct))
                    .lineLimit(1)
                bar(pct)
            } else {
                Text(verbatim: "—%").font(.system(size: 13).monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .fixedSize()
    }

    private func bar(_ pct: Double) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.12)).frame(width: 48, height: 5)
            Capsule().fill(pressureColor(pct)).frame(width: max(3, 48 * pct), height: 5)
        }
    }

    private func pressureColor(_ pct: Double) -> Color {
        switch pct {
        case ..<0.8:  return Color.primary.opacity(0.45)
        case ..<0.95: return .orange
        default:      return .red
        }
    }

    // MARK: - Readings (exact when fresh, else local estimate)

    private var session5hPct: Double? {
        if let ex = appState.exactSnapshot, ex.isFresh() { return Double(ex.fiveHour.utilization) / 100.0 }
        return appState.snapshot.session5h.percentUsed
    }
    private var weeklyAllPct: Double? {
        if let ex = appState.exactSnapshot, ex.isFresh() { return Double(ex.sevenDay.utilization) / 100.0 }
        return appState.snapshot.weeklyAll.percentUsed
    }
    private var weeklySonnetPct: Double? {
        if let ex = appState.exactSnapshot, ex.isFresh() { return Double(ex.sevenDaySonnet.utilization) / 100.0 }
        return appState.snapshot.weeklySonnet.percentUsed
    }
}
