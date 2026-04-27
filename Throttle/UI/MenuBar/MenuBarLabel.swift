import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if !appState.claudeCodeDetected {
            Image(systemName: "gauge.with.dots.needle.0percent")
        } else if !appState.snapshot.hasAnyData {
            Image(systemName: "gauge.with.dots.needle.0percent")
        } else if let pct = appState.snapshot.session5h.percentUsed {
            Label("\(Int(pct * 100))%", systemImage: meterIcon(for: pct))
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
        }
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
