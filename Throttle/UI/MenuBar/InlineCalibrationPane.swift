import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

struct InlineCalibrationPane: View {
    @Environment(AppState.self) var appState
    @State var caps: [WindowKind: Int] = [:]
    @State var recalPct: [WindowKind: Int] = [
        .session5h: 50, .weeklyAll: 50, .weeklySonnet: 50
    ]

    /// Preset buttons — chosen to cover Pro / Max 5× / Max 20× ballparks for each window.
    /// Avoids TextField, which on macOS 26.5 triggers a RealityBridge/Metal preload
    /// crash inside the menu-bar popover. Power-user manual entry returns in v1.1
    /// once Apple ships a fix or we move calibration into a dedicated NSWindow.
    static let presets: [WindowKind: [(label: String, tokens: Int)]] = [
        .session5h: [
            ("4M", 4_000_000),
            ("8M", 8_000_000),
            ("20M", 20_000_000)
        ],
        .weeklyAll: [
            ("60M", 60_000_000),
            ("200M", 200_000_000),
            ("800M", 800_000_000)
        ],
        .weeklySonnet: [
            ("60M", 60_000_000),
            ("200M", 200_000_000),
            ("800M", 800_000_000)
        ]
    ]

    static let planLabels = ["Pro", "Max 5×", "Max 20×"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader(label: "Calibration", desc: "Set your three usage caps")
            calWindow(.session5h, "Session", "5-hour")
            SettingsHair()
            calWindow(.weeklyAll, "Weekly", "all models")
            SettingsHair()
            calWindow(.weeklySonnet, "Weekly", ScopedCapModel.subtitle)
            SettingsHair()
            recalBlock
            SettingsHair()
            HStack {
                Spacer(minLength: 0)
                SettingsButton(title: "Reset all", role: .destructive) { resetAll() }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .task { await loadCurrent() }
    }

    @ViewBuilder
    func calWindow(_ kind: WindowKind, _ name: String, _ sub: String) -> some View {
        let selected = caps[kind] ?? 0
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(name).font(.system(size: 12.5, weight: .semibold))
                Text(sub).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("cap \(formatTokens(selected))")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(Array((Self.presets[kind] ?? []).enumerated()), id: \.element.tokens) { i, preset in
                    calChip(label: preset.label,
                            plan: Self.planLabels[min(i, Self.planLabels.count - 1)],
                            on: selected == preset.tokens) { save(kind: kind, capTokens: preset.tokens) }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    func calChip(label: String, plan: String, on: Bool, action: @escaping () -> Void) -> some View {
        let fg: Color = on ? .accentColor : .secondary
        let planFg: Color = on ? .accentColor.opacity(0.8) : .secondary.opacity(0.6)
        let stroke: Color = on ? .accentColor.opacity(0.45) : .primary.opacity(0.12)
        let fill: Color = on ? .accentColor.opacity(0.13) : .clear
        return Button(action: action) {
            HStack(spacing: 5) {
                Text(label).font(.system(size: 11.5).monospacedDigit())
                Text(plan).font(.system(size: 10)).foregroundStyle(planFg)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .foregroundStyle(fg)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(fill)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(stroke, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }

    var recalBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Recalibrate — read claude.ai's % and Apply")
                .font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                .textCase(.uppercase).foregroundStyle(.tertiary)
            ForEach([WindowKind.session5h, .weeklyAll, .weeklySonnet], id: \.self) { kind in
                recalRow(kind)
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 12)
    }

    @ViewBuilder
    func recalRow(_ kind: WindowKind) -> some View {
        let used = window(for: kind)?.usedTokens ?? 0
        let pct = recalPct[kind] ?? 50
        let canApply = used > 0 && pct > 0 && pct <= 100
        HStack(spacing: 8) {
            Text(recalLabel(kind)).font(.system(size: 12)).frame(width: 92, alignment: .leading)
            Button { adjustPct(kind, by: -5) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).accessibilityLabel(String(localized: "Decrease by 5 percent"))
            Text("\(pct)%").font(.system(size: 12).monospacedDigit()).frame(minWidth: 36, alignment: .center)
            Button { adjustPct(kind, by: 5) } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.plain).accessibilityLabel(String(localized: "Increase by 5 percent"))
            Spacer(minLength: 0)
            Button { applyRecalibration(kind: kind) } label: {
                Text("Apply").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(canApply ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain).disabled(!canApply)
        }
    }

    func recalLabel(_ kind: WindowKind) -> String {
        switch kind {
        case .session5h:    return String(localized: "Session 5h")
        case .weeklyAll:    return String(localized: "Weekly all")
        case .weeklySonnet: return String(localized: "Weekly Sonnet")
        }
    }

    func adjustPct(_ kind: WindowKind, by delta: Int) {
        let current = recalPct[kind] ?? 50
        recalPct[kind] = min(100, max(1, current + delta))
    }

    func window(for kind: WindowKind) -> UsageSnapshot.Window? {
        switch kind {
        case .session5h:    return appState.snapshot.session5h
        case .weeklyAll:    return appState.snapshot.weeklyAll
        case .weeklySonnet: return appState.snapshot.weeklySonnet
        }
    }

    func applyRecalibration(kind: WindowKind) {
        guard let used = window(for: kind)?.usedTokens, used > 0,
              let pct = recalPct[kind], pct > 0 else { return }
        // newCap = used / (pct / 100) using integer math, rounded to nearest 1k.
        let newCap = max(1, (used * 100) / pct)
        let rounded = ((newCap + 500) / 1000) * 1000
        save(kind: kind, capTokens: rounded)
    }

    func formatTokens(_ n: Int) -> String {
        if n == 0 { return "—" }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }

    func loadCurrent() async {
        guard let url = try? DatabaseManager.databaseURL(),
              let pool = try? DatabasePool(path: url.path) else { return }
        let loaded: [WindowKind: Int] = (try? await Task.detached {
            try pool.read { db in
                var result: [WindowKind: Int] = [:]
                for kind in WindowKind.allCases {
                    result[kind] = try DatabaseQueries.calibration(in: db, kind: kind)?.capTokens ?? 0
                }
                return result
            }
        }.value) ?? [:]
        await MainActor.run { caps = loaded }
    }

    func save(kind: WindowKind, capTokens: Int) {
        guard let url = try? DatabaseManager.databaseURL(),
              let pool = try? DatabasePool(path: url.path) else { return }
        try? pool.write { db in
            try CalibrationEngine.setManual(in: db, kind: kind, capTokens: capTokens)
        }
        caps[kind] = capTokens
        appState.refresh()
    }

    func resetAll() {
        guard let url = try? DatabaseManager.databaseURL(),
              let pool = try? DatabasePool(path: url.path) else { return }
        try? pool.write { db in
            for kind in WindowKind.allCases {
                try CalibrationEngine.reset(in: db, kind: kind)
            }
        }
        for kind in WindowKind.allCases { caps[kind] = 0 }
        appState.refresh()
    }
}
