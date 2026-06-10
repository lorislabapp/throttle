import SwiftUI

/// The cockpit: Throttle's decision layer wrapped around a real `claude`
/// terminal. The terminal is a commodity container; the product is the
/// instrument — the binding number, an honest forecast, the session cost, and
/// the local config cost-sources Anthropic's own dashboard never surfaces.
///
/// Two density levels: **full** (Strip A + collapsible Rail B) and **compact**
/// (an ambient HUD over a full-bleed terminal). Every value is real or hidden —
/// never a faked number (see the golden rule in UI-SPEC-cockpit.md).
struct CockpitWindowRoot: View {
    @Environment(AppState.self) private var appState
    @State private var vm = CockpitViewModel()
    @State private var terminalController = CockpitTerminalController()
    @State private var railOpen = true
    @State private var compact = false

    var body: some View {
        Group {
            if compact { compactLayout } else { fullLayout }
        }
        .onAppear { vm.start(appState: appState) }
        .onDisappear { vm.stop() }
    }

    // MARK: - Full layout

    private var fullLayout: some View {
        VStack(spacing: 0) {
            identityBar
            hairline
            if let b = binding, b.pct >= 0.80 {
                atLimitBanner(b); hairline
            }
            stripA
            hairline
            HStack(spacing: 0) {
                terminal
                if railOpen {
                    Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1)
                    railB
                }
            }
        }
    }

    private var compactLayout: some View {
        ZStack(alignment: .topTrailing) {
            terminal
            if let b = binding { hudChip(b).padding(12) }
            compactExit.padding(12)
        }
    }

    private var terminal: some View {
        CockpitTerminalView(controller: terminalController)
            .background(Color(nsColor: .textBackgroundColor))
    }

    private var hairline: some View {
        Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
    }

    // MARK: - Identity bar

    private var identityBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 14)).foregroundStyle(.primary.opacity(0.85))
            Text("Throttle Cockpit").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            appState.isPro ? pill("PRO") : pill("FREE")
            if isExact { exactPill }
            iconButton("rectangle.righthalf.inset.filled", on: railOpen) { railOpen.toggle() }
                .help("Toggle inspector rail")
            iconButton("arrow.down.right.and.arrow.up.left", on: false) { compact = true }
                .help("Compact mode")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    private var compactExit: some View {
        Button { compact = false } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .padding(7)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("Exit compact mode")
    }

    private func iconButton(_ name: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? Color.accentColor : .secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func pill(_ t: String) -> some View {
        Text(t).font(.system(size: 9, weight: .heavy)).tracking(0.06)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(.secondary)
    }

    private var exactPill: some View {
        HStack(spacing: 4) {
            Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 4, height: 4)
            Text("EXACT")
        }
        .font(.system(size: 9, weight: .heavy)).tracking(0.06)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.primary, in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Strip A (decision)

    private var stripA: some View {
        HStack(alignment: .center, spacing: 0) {
            bindingCell
            if let f = forecast {
                stripDivider; forecastCell(f)
            }
            if vm.data.sessionTokens != nil {
                stripDivider; sessionCell
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }

    private var stripDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1, height: 44)
    }

    @ViewBuilder
    private var bindingCell: some View {
        VStack(alignment: .leading, spacing: 7) {
            dlLabel("BINDING NOW")
            if let b = binding {
                bindingHero(b)
                headroomBar(b.pct, degraded: b.degraded, width: 150)
            } else {
                Text(verbatim: "—").font(.system(size: 30, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private func bindingHero(_ b: Reading) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            heroNumber(b)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(b.name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.primary)
                    Text(b.sub).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Text(b.resetText).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
    }

    private func heroNumber(_ b: Reading) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if b.degraded {
                Text(verbatim: "≈").font(.system(size: 18)).foregroundStyle(.secondary)
            }
            Text("\(Int((b.pct * 100).rounded()))")
                .font(.system(size: 30, weight: .medium).monospacedDigit()).tracking(-0.6)
            Text(verbatim: "%").font(.system(size: 15)).opacity(0.55)
        }
        .foregroundStyle(b.degraded ? Color.secondary : pressureColor(b.pct))
    }

    private func forecastCell(_ f: Forecast) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            dlLabel("FORECAST")
            HStack(spacing: 7) {
                Image(systemName: f.tone == .neutral ? "clock" : "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(forecastTint(f.tone))
                Text(f.text).font(.system(size: 12)).foregroundStyle(.secondary)
                estTag
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .frame(minWidth: 150, alignment: .leading)
    }

    private var sessionCell: some View {
        VStack(alignment: .leading, spacing: 7) {
            dlLabel("THIS SESSION")
            HStack(spacing: 5) {
                Text(fmtTokens(vm.data.sessionTokens ?? 0))
                    .font(.system(size: 14, weight: .medium).monospacedDigit()).foregroundStyle(.primary)
                Text("tok").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                if let c = vm.data.sessionCostEUR {
                    Text("· \(fmtEUR(c))").font(.system(size: 14, weight: .medium).monospacedDigit())
                        .foregroundStyle(.primary)
                }
            }
            if let all = vm.data.allTimeCostEUR {
                Text("this session · \(fmtEUR(all)) all-time")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    // MARK: - Rail B (Environment & cost sources)

    private var railB: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                railSection("OTHER WINDOWS") { otherWindowsList }
                railHairline
                if !vm.data.modelSplit.isEmpty {
                    railSection("MODEL SPLIT") { modelSplitView }
                    railHairline
                }
                if vm.data.config.hasAnything {
                    railSection("CONFIG WEIGHT") { configWeightView }
                    railHairline
                }
                if !vm.data.sessions.isEmpty {
                    railSection("RECENT SESSIONS") { sessionsView }
                }
            }
        }
        .frame(width: 232)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sessionsView: some View {
        VStack(spacing: 10) {
            ForEach(vm.data.sessions) { s in
                sessionRow(s)
            }
        }
    }

    private func sessionRow(_ s: CockpitSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if s.isCurrent {
                    Circle().fill(Color.green).frame(width: 5, height: 5)
                }
                Text(relativeTime(s.lastActivity))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)
                Spacer(minLength: 4)
                Button { terminalController.run("claude --resume \(s.id)") } label: {
                    Text("Resume").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Type `claude --resume` into the terminal")
                .disabled(s.isCurrent)
                .opacity(s.isCurrent ? 0.35 : 1)
            }
            HStack(spacing: 5) {
                Text(fmtTokens(s.weightedTokens)).font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("tok").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                if let c = s.costEUR {
                    Text("· \(fmtEUR(c))").font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let t = s.topTier {
                    Text("· \(tierName(t))").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func relativeTime(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }

    private var railHairline: some View {
        Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
    }

    private func railSection<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            dlLabel(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var otherWindowsList: some View {
        VStack(spacing: 7) {
            ForEach(others, id: \.kind) { r in
                HStack(spacing: 9) {
                    Text("\(r.name) \(r.sub)").font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    miniBar(r.pct, degraded: r.degraded)
                    Text("\(r.degraded ? "≈" : "")\(Int((r.pct * 100).rounded()))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(r.degraded ? Color.secondary : .primary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private var modelSplitView: some View {
        let slices = vm.data.modelSplit.sorted { $0.weightedTokens > $1.weightedTokens }
        let total = max(1, slices.reduce(0) { $0 + $1.weightedTokens })
        let top = slices.first
        let topPct = top.map { Int((Double($0.weightedTokens) / Double(total) * 100).rounded()) } ?? 0
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(slices.enumerated()), id: \.offset) { idx, s in
                        Capsule().fill(Color.primary.opacity(splitOpacity(idx)))
                            .frame(width: max(2, geo.size.width * Double(s.weightedTokens) / Double(total)))
                    }
                }
            }
            .frame(height: 6)
            if let top {
                HStack(spacing: 4) {
                    Text(tierName(top.tier)).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)
                    Text("\(topPct)%").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    if top.tier == .opus, topPct > 70 {
                        Text("· cost-heavy").font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var configWeightView: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let md = vm.data.config.claudeMdTokens {
                configRow("CLAUDE.md", value: "≈\(fmtTokens(md)) tok / session")
            }
            if vm.data.config.mcpCount > 0 {
                configRow("MCP servers", value: "\(vm.data.config.mcpCount)")
            }
            if vm.data.config.skillCount > 0 {
                configRow("Skills", value: "\(vm.data.config.skillCount)")
            }
        }
    }

    private func configRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value).font(.system(size: 11).monospacedDigit()).foregroundStyle(.primary)
        }
    }

    // MARK: - HUD (compact)

    private func hudChip(_ b: Reading) -> some View {
        let crit = b.pct >= 0.95, warn = b.pct >= 0.80
        return VStack(alignment: .leading, spacing: 7) {
            Text("\(b.name) \(b.sub)".uppercased())
                .font(.system(size: 9, weight: .bold)).tracking(0.5)
                .foregroundStyle(.white.opacity(0.5))
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if b.degraded { Text(verbatim: "≈").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)) }
                Text("\(Int((b.pct * 100).rounded()))")
                    .font(.system(size: 22, weight: .medium).monospacedDigit())
                Text(verbatim: "%").font(.system(size: 11)).opacity(0.55)
            }
            .foregroundStyle(hudInk(b.pct))
            Capsule().fill(Color.white.opacity(0.14)).frame(width: 140, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(hudInk(b.pct)).frame(width: max(3, 140 * min(1, b.pct)), height: 4)
                }
            if warn, let f = forecast {
                Text(f.text).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.85))
            }
            if let tok = vm.data.sessionTokens {
                Text("\(fmtTokens(tok)) tok\(vm.data.sessionCostEUR.map { " · \(fmtEUR($0))" } ?? "") session")
                    .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(crit || warn ? 13 : 11)
        .frame(width: crit ? 196 : (warn ? 188 : 150), alignment: .leading)
        .environment(\.colorScheme, .dark)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(hudInk(b.pct).opacity(crit || warn ? 0.4 : 0.12), lineWidth: 1))
    }

    private func hudInk(_ pct: Double) -> Color {
        switch pct {
        case ..<0.80: return .white
        case ..<0.95: return .orange
        default:      return .red
        }
    }

    // MARK: - Small parts

    private func dlLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 9.5, weight: .bold)).tracking(0.8).foregroundStyle(.tertiary)
    }

    private var estTag: some View {
        Text("est").font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15), lineWidth: 1))
            .foregroundStyle(.tertiary)
    }

    private func atLimitBanner(_ b: Reading) -> some View {
        let crit = b.pct >= 0.95
        let tint: Color = crit ? .red : .orange
        let text = crit
            ? "\(b.name) \(b.sub) is over its cap — finish up or switch to Sonnet."
            : "Approaching the \(b.name) \(b.sub) cap — ease off or switch to Sonnet."
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(tint)
            Text(text).font(.system(size: 12.5)).foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10))
    }

    private func headroomBar(_ pct: Double, degraded: Bool, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.10)).frame(width: width, height: 5)
            tick(at: 0.80, width: width)
            tick(at: 0.95, width: width)
            Capsule().fill(degraded ? Color.secondary : pressureColor(pct))
                .frame(width: max(3, width * min(1, pct)), height: 5)
        }
        .frame(width: width, height: 5)
    }

    private func tick(at frac: Double, width: CGFloat) -> some View {
        Rectangle().fill(Color.primary.opacity(0.22)).frame(width: 1, height: 5).offset(x: width * frac)
    }

    private func miniBar(_ pct: Double, degraded: Bool) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.12)).frame(width: 44, height: 4)
            Capsule().fill(degraded ? Color.secondary : pressureColor(pct))
                .frame(width: max(3, 44 * min(1, pct)), height: 4)
        }
    }

    private func pressureColor(_ pct: Double) -> Color {
        switch pct {
        case ..<0.80: return Color.primary.opacity(0.55)
        case ..<0.95: return .orange
        default:      return .red
        }
    }

    private func forecastTint(_ tone: Forecast.Tone) -> Color {
        switch tone {
        case .neutral: return Color.primary.opacity(0.45)
        case .warn:    return .orange
        case .crit:    return .red
        }
    }

    private func splitOpacity(_ idx: Int) -> Double {
        switch idx { case 0: return 0.70; case 1: return 0.40; case 2: return 0.18; default: return 0.10 }
    }

    private func tierName(_ t: ModelTier) -> String {
        switch t {
        case .opus: return "Opus"; case .sonnet: return "Sonnet"
        case .haiku: return "Haiku"; case .other: return "Other"
        }
    }

    // MARK: - Forecast (honest extrapolation; always an estimate)

    struct Forecast {
        enum Tone { case neutral, warn, crit }
        let minutes: Double
        let msgs: Int?
        let tone: Tone
        var text: String {
            let t = Self.fmtMinutes(minutes)
            if let m = msgs, m >= 0 { return "≈\(t) · ≈\(m) msgs to cap" }
            return "≈\(t) to cap"
        }
        static func fmtMinutes(_ m: Double) -> String {
            let mins = max(0, Int(m.rounded()))
            if mins >= 60 { return "\(mins / 60)h \(mins % 60)m" }
            return "\(mins)m"
        }
    }

    private var forecast: Forecast? {
        guard let b = binding, let cap = b.capTokens, cap > 0,
              let burn = vm.data.burn, burn.tokensPerMinute > 0 else { return nil }
        let remaining = Double(cap) * (1 - b.pct)
        guard remaining > 0 else { return nil }   // at/over cap → the banner speaks instead
        let minutes = remaining / burn.tokensPerMinute
        let msgs = vm.data.avgTokensPerMessage.map { Int((remaining / $0).rounded()) }
        let tone: Forecast.Tone = b.pct >= 0.95 ? .crit : (b.pct >= 0.80 ? .warn : .neutral)
        return Forecast(minutes: minutes, msgs: msgs, tone: tone)
    }

    // MARK: - Readings (exact when fresh, else local estimate)

    private struct Reading {
        let kind: WindowKind
        let name: String
        let sub: String
        let pct: Double
        let capTokens: Int?
        let resetText: String
        let degraded: Bool
    }

    private var isExact: Bool { appState.exactSnapshot?.isFresh() == true }

    private var readings: [Reading] {
        [
            reading(.session5h, name: "Session", sub: "5h",
                    local: appState.snapshot.session5h, exact: appState.exactSnapshot?.fiveHour),
            reading(.weeklyAll, name: "Weekly", sub: "all models",
                    local: appState.snapshot.weeklyAll, exact: appState.exactSnapshot?.sevenDay),
            reading(.weeklySonnet, name: "Weekly", sub: "Sonnet",
                    local: appState.snapshot.weeklySonnet, exact: appState.exactSnapshot?.sevenDaySonnet),
        ].compactMap { $0 }
    }

    private var binding: Reading? { readings.max { $0.pct < $1.pct } }

    private var others: [Reading] {
        guard let b = binding else { return readings }
        return readings.filter { $0.kind != b.kind }
    }

    private func reading(
        _ kind: WindowKind, name: String, sub: String,
        local: UsageSnapshot.Window, exact: ExactSnapshot.Window?
    ) -> Reading? {
        let degraded = !isExact
        let pct: Double?
        let resetSeconds: Int64
        if isExact, let exact {
            pct = Double(exact.utilization) / 100.0
            resetSeconds = exact.resetsAt.map { Int64(max(0, $0.timeIntervalSinceNow)) } ?? local.resetInSeconds
        } else {
            pct = local.percentUsed
            resetSeconds = local.resetInSeconds
        }
        guard let pct else { return nil }
        return Reading(kind: kind, name: name, sub: sub, pct: pct, capTokens: local.capTokens,
                       resetText: "resets in \(formatReset(resetSeconds))", degraded: degraded)
    }

    private func formatReset(_ seconds: Int64) -> String {
        let s = max(0, seconds), h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }

    private func fmtTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1000)k" }
        return "\(n)"
    }

    private func fmtEUR(_ v: Double) -> String { String(format: "€%.2f", v) }
}
