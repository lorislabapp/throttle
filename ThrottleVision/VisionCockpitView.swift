import SwiftUI
import ThrottleShared

/// Spatial cockpit: the binding meter as a large glass ring, the two windows as
/// stat plates, and the live sessions as a grid of tiles — all fed by `MirrorStore`
/// (CloudKit + LAN peer), read-only.
struct VisionCockpitView: View {
    @State private var store = MirrorStore.shared

    // Exact cockpit palette (shared with Mac/iOS).
    private static let accent = Color(red: 0.00, green: 0.44, blue: 0.89)   // #0071E3
    private static let warn   = Color(red: 1.00, green: 0.62, blue: 0.04)   // #FF9F0A
    private static let crit   = Color(red: 1.00, green: 0.23, blue: 0.19)   // #FF3B30
    private static let ok     = Color(red: 0.20, green: 0.78, blue: 0.35)   // #34C759

    private static func tint(_ util: Int) -> Color {
        switch util { case 95...: return crit; case 80..<95: return warn; default: return accent }
    }

    var body: some View {
        Group {
            if let snap = store.latest {
                cockpit(snap)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .padding(40)
        .glassBackgroundEffect()
    }

    // MARK: - Populated

    private func cockpit(_ snap: ThrottleMirrorSnapshot) -> some View {
        VStack(spacing: 34) {
            HStack(alignment: .center, spacing: 48) {
                meter(snap.bindingWindow)
                VStack(alignment: .leading, spacing: 18) {
                    Text(snap.deviceName).font(.system(size: 26, weight: .semibold))
                    windowPlate("5-hour session", snap.fiveHour)
                    windowPlate("7-day", snap.sevenDay)
                    HStack(spacing: 28) {
                        stat("Cost 7d", String(format: "€%.2f", snap.weeklyCostEUR))
                        stat("Tokens 7d", compact(snap.weeklyTokens))
                        stat("Saved", compact(snap.savedTokensThisWeek))
                    }
                }
                Spacer(minLength: 0)
            }
            sessions(snap.tabs)
        }
    }

    private func meter(_ w: WindowMirror) -> some View {
        let c = Self.tint(w.utilization)
        return ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 22)
            Circle()
                .trim(from: 0, to: max(0.001, Double(w.utilization) / 100))
                .stroke(c, style: StrokeStyle(lineWidth: 22, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 4) {
                Text("\(w.utilization)").font(.system(size: 84, weight: .bold, design: .rounded)).foregroundStyle(c)
                Text("USED").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary).tracking(2)
                if let reset = w.resetsAt {
                    Text("resets \(reset, style: .relative)").font(.system(size: 13)).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: 240, height: 240)
    }

    private func windowPlate(_ title: String, _ w: WindowMirror) -> some View {
        HStack {
            Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            Text("\(w.utilization)%").font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Self.tint(w.utilization))
        }
        .frame(width: 320)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded))
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func sessions(_ tabs: [TabMirror]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 16)], spacing: 16) {
            ForEach(tabs, id: \.id) { t in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle().fill(stateColor(t)).frame(width: 10, height: 10)
                        Text(t.projectName).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    }
                    Text(subtitle(t)).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    HStack {
                        if let eur = t.eur { Text(String(format: "€%.2f", eur)).font(.system(size: 13, design: .rounded)) }
                        Spacer()
                        if let tok = t.tokens { Text(compact(tok)).font(.system(size: 13, design: .rounded)).foregroundStyle(.secondary) }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                .hoverEffect()
            }
        }
    }

    private func subtitle(_ t: TabMirror) -> String {
        [t.model, t.state].compactMap { $0 }.joined(separator: " · ")
    }

    private func stateColor(_ t: TabMirror) -> Color {
        if t.rateLimitedUntil != nil { return Self.crit }
        if t.needsInput { return Self.warn }
        if t.isLive { return Self.ok }
        return .secondary
    }

    private func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 54)).foregroundStyle(Self.accent)
            Text("Waiting for your Mac").font(.system(size: 24, weight: .semibold))
            Text("Open Throttle on your Mac (same iCloud account) and enable the iOS companion mirror.")
                .font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
    }
}
