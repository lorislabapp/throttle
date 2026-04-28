import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if !appState.claudeCodeDetected {
            Image(systemName: "gauge.with.dots.needle.0percent")
        } else if !appState.snapshot.hasAnyData {
            Image(systemName: "gauge.with.dots.needle.0percent")
        } else if let pct = highestPressurePercent() {
            // Show the window closest to its limit — that's the one that
            // will actually throttle the user. Hiding a 100% weekly cap
            // behind a 0% session pill is misleading.
            Label("\(Int(pct * 100))%", systemImage: meterIcon(for: pct))
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
        }
    }

    private func highestPressurePercent() -> Double? {
        // Prefer exact-mode data when fresh — those are the numbers Anthropic
        // is actually rate-limiting against. Fall back to local rolling-window
        // math otherwise.
        if let ex = appState.exactSnapshot, ex.isFresh() {
            let exactPcts = [
                Double(ex.fiveHour.utilization),
                Double(ex.sevenDay.utilization),
                Double(ex.sevenDaySonnet.utilization)
            ].max() ?? 0
            return exactPcts / 100.0
        }
        let pcts = [
            appState.snapshot.session5h.percentUsed,
            appState.snapshot.weeklyAll.percentUsed,
            appState.snapshot.weeklySonnet.percentUsed
        ].compactMap { $0 }
        return pcts.max()
    }

    private func meterIcon(for percent: Double) -> String {
        switch percent {
        case ..<0.5:  return "gauge.with.dots.needle.bottom.50percent"
        case ..<0.8:  return "gauge.with.dots.needle.50percent"
        case ..<0.95: return "gauge.with.dots.needle.67percent"
        default:      return "gauge.with.dots.needle.100percent"
        }
    }
}
