import SwiftUI
import AppKit

/// The multi-session Cockpit: several real `claude` sessions (one per project)
/// under ONE shared decision layer. The binding window + machine memory are
/// global (every session draws on the same account limits and the same Mac);
/// project + uptime are per-session. Three switchable layouts — Tabs / Rail /
/// Overview — over the same live terminal stack (Claude Design: A/B/C).
///
/// Golden rule: per-session cost/model render only when real (nil → omitted),
/// never invented. Pressure colour (orange/red) is earned only under genuine
/// cap or memory pressure.
struct MultiCockpitRoot: View {
    @Environment(AppState.self) private var appState
    @State private var model = MultiCockpitModel()
    @State private var showPicker = false
    @State private var showInspector = false

    private let hair = Color.primary.opacity(0.10)
    private let track = Color.primary.opacity(0.08)

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(hair).frame(height: 1)
            globalStrip
            if model.gated { gateBanner }
            HStack(spacing: 0) {
                content
                if showInspector {
                    Rectangle().fill(hair).frame(width: 1)
                    CockpitAuditInspector()
                }
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .overlay(alignment: .topTrailing) {
            if showPicker { picker.padding(.top, 96).padding(.trailing, 14) }
        }
        .onAppear { model.start(appState: appState) }
        .onDisappear { model.stop() }
    }

    // MARK: - Top bar (switcher + pills)

    private var topBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            Text("Throttle Cockpit").font(.system(size: 12.5, weight: .semibold))
            Spacer(minLength: 12)
            viewSwitcher
            Spacer(minLength: 12)
            Button { showInspector.toggle() } label: {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(showInspector ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain).help("Audit inspector")
            if appState.isPro { pill("PRO", soft: true) }
            if appState.exactSnapshot != nil { pill("EXACT", solid: true) }
        }
        .padding(.horizontal, 14).frame(height: 40)
    }

    private var viewSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(MultiCockpitModel.ViewMode.allCases) { mode in
                let on = model.viewMode == mode
                Button { model.viewMode = mode } label: {
                    Text(mode.label)
                        .font(.system(size: 11.5, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background(on ? Color.accentColor.opacity(0.12) : .clear,
                                   in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Global strip (binding + machine)

    private var globalStrip: some View {
        HStack(spacing: 0) {
            bindingCell
            Rectangle().fill(hair).frame(width: 1, height: 48)
            machineCell
            Spacer(minLength: 0)
        }
        .frame(height: 76)
        .overlay(alignment: .bottom) { Rectangle().fill(hair).frame(height: 1) }
    }

    private var bindingCell: some View {
        VStack(alignment: .leading, spacing: 5) {
            gLabel("BINDING · ALL SESSIONS")
            if let b = model.binding {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    HStack(spacing: 0) {
                        if b.estimate { Text("≈").font(.system(size: 13)).foregroundStyle(.tertiary) }
                        Text("\(b.pct)").font(.system(size: 26, weight: .regular, design: .monospaced))
                            .foregroundStyle(toneColor(b.pct, estimate: b.estimate))
                        Text("%").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Text("\(b.name)\nresets \(b.reset)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                bar(fraction: Double(b.pct) / 100, tone: toneColor(b.pct, estimate: false),
                    estimate: b.estimate, ticks: true)
            } else {
                Text("—").font(.system(size: 26, weight: .regular, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 9).frame(width: 240, alignment: .leading)
    }

    private var machineCell: some View {
        let m = model.machine
        let tint: Color = m.critical ? .red : (m.underPressure ? .orange : .secondary)
        return VStack(alignment: .leading, spacing: 5) {
            gLabel("MACHINE")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 0) {
                    Text(gb(m.usedBytes)).font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundStyle(m.underPressure ? tint : .primary)
                    Text("/\(gb(m.totalBytes))").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                HStack(spacing: 4) {
                    Circle().fill(tint).frame(width: 6, height: 6)
                    Text(pressureLabel(m) + " · \(m.claudeCount) claude\(m.claudeCount == 1 ? "" : "s")"
                         + (m.swapUsedBytes > 0 ? " · swap \(gb(m.swapUsedBytes))" : ""))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            bar(fraction: m.usedFraction, tone: tint, estimate: false, ticks: false).frame(width: 168)
        }
        .padding(.horizontal, 15).padding(.vertical, 9).frame(minWidth: 196, alignment: .leading)
    }

    private var gateBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.red)
            HStack(spacing: 0) {
                Text("Mac saturated").font(.system(size: 11.5, weight: .semibold))
                Text(" — close a session before opening another.").font(.system(size: 11.5))
            }
            .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.red.opacity(0.10))
    }

    // MARK: - Content (the active layout)

    @ViewBuilder
    private var content: some View {
        if model.sessions.isEmpty {
            emptyState
        } else {
            switch model.viewMode {
            case .tabs:    tabsLayout
            case .rail:    railLayout
            case .mission: missionLayout
            }
        }
    }

    private var terminal: some View {
        MultiTerminalStack(sessions: model.sessions, activeID: model.activeID)
            .background(Color.black)
    }

    // MARK: A — Tab bar

    private var tabsLayout: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(model.sessions) { s in
                        let on = s.id == (model.active?.id)
                        Button { model.activeID = s.id } label: {
                            HStack(spacing: 8) {
                                stateDot
                                Text(s.projectName).font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(on ? .primary : .secondary)
                                Button { model.close(s.id) } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.tertiary)
                                }.buttonStyle(.plain)
                            }
                            .padding(.horizontal, 12).frame(minHeight: 40)
                            .background(on ? Color.primary.opacity(0.06) : .clear)
                            .overlay(alignment: .bottom) {
                                if on { Rectangle().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 10) }
                            }
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    newTabButton
                }
                .padding(.horizontal, 6)
            }
            .overlay(alignment: .bottom) { Rectangle().fill(hair).frame(height: 1) }
            terminal
        }
    }

    private var newTabButton: some View {
        Button { if !model.gated { showPicker.toggle() } } label: {
            Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.gated ? Color.secondary : Color.accentColor)
                .padding(.horizontal, 12).frame(minHeight: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(model.gated)
        .help(model.gated ? "Mac saturated" : "New session")
    }

    // MARK: B — Project rail

    private var railLayout: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    gLabel("SESSIONS · \(model.sessions.count)")
                    Spacer()
                }.padding(.horizontal, 13).padding(.vertical, 9)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.sessions) { s in railRow(s) }
                    }.padding(.horizontal, 8).padding(.vertical, 4)
                }
                Spacer(minLength: 0)
                Rectangle().fill(hair).frame(height: 1)
                Button { if !model.gated { showPicker.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                        Text("New session").font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(model.gated ? Color.secondary : Color.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11).padding(.vertical, 9).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(model.gated)
            }
            .frame(width: 234)
            .overlay(alignment: .trailing) { Rectangle().fill(hair).frame(width: 1) }
            terminal
        }
    }

    private func railRow(_ s: CockpitTab) -> some View {
        let on = s.id == model.active?.id
        return Button { model.activeID = s.id } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    stateDot
                    Text(s.projectName).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(on ? .primary : .secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if let model = s.model { modelChip(model) }
                }
                HStack(spacing: 8) {
                    if let e = s.eur {
                        Text(String(format: "€%.2f", e)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    if let t = s.tokens, t > 0 {
                        Text(fmtTok(t)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Text("up \(uptime(s.startedAt))").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay { if on { RoundedRectangle(cornerRadius: 9).stroke(hair, lineWidth: 1) } }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: C — Mission control

    private var missionLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("All sessions").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(model.sessions.count) running · \(model.machine.claudeCount) claude processes")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }.padding(.horizontal, 18).padding(.top, 13).padding(.bottom, 4)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(model.sessions) { s in missionCard(s) }
                    addCard
                }.padding(.horizontal, 18).padding(.vertical, 12)
            }
        }
    }

    private func missionCard(_ s: CockpitTab) -> some View {
        let active = s.id == model.active?.id
        return Button { model.activeID = s.id; model.viewMode = .tabs } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    stateDot
                    Text(s.projectName).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 0)
                    if let m = s.model { modelChip(m) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.eur.map { String(format: "€%.2f", $0) } ?? "—")
                        .font(.system(size: 19, design: .monospaced)).foregroundStyle(.primary)
                    Text("up \(uptime(s.startedAt))").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                HStack {
                    Text("Focus terminal›").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 13).frame(minHeight: 128, alignment: .topLeading)
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(active ? Color.accentColor : hair, lineWidth: active ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }

    private var addCard: some View {
        Button { if !model.gated { showPicker.toggle() } } label: {
            VStack(spacing: 7) {
                Image(systemName: "plus").font(.system(size: 18, weight: .medium))
                Text(model.gated ? "Mac saturated" : "New session").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(model.gated ? Color.secondary : Color.accentColor)
            .frame(maxWidth: .infinity, minHeight: 128)
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(hair, style: StrokeStyle(lineWidth: 1, dash: [4, 4])) }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).disabled(model.gated)
    }

    // MARK: - Empty + picker

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "square.split.2x2").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("No sessions running").font(.system(size: 15, weight: .semibold)).padding(.top, 16)
            Text("Start your first claude session — Throttle keeps every project's headroom, cost and machine load in view as you work.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 320).padding(.top, 6)
            Button { showPicker = true } label: {
                HStack(spacing: 8) { Image(systemName: "plus"); Text("Start a session") }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).padding(.top, 18)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("OPEN A SESSION IN…").font(.system(size: 9.5, weight: .semibold)).tracking(0.7)
                .foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.top, 10).padding(.bottom, 5)
            let projects = model.recentProjects()
            if projects.isEmpty {
                Text("No recent projects").font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 13).padding(.vertical, 8)
            } else {
                ForEach(projects) { p in
                    Button {
                        model.newSession(projectName: p.name, cwd: p.cwd)
                        model.viewMode = model.viewMode == .mission ? .tabs : model.viewMode
                        showPicker = false
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(.secondary)
                            Text(p.name).font(.system(size: 12.5)).foregroundStyle(.primary).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 13).padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
        .frame(width: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).stroke(hair, lineWidth: 1) }
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }

    // MARK: - Bits

    private var stateDot: some View { Circle().fill(Color.green).frame(width: 6, height: 6) }

    private func modelChip(_ m: String) -> some View {
        Text(m).font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(track, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.secondary)
    }

    private func gLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 8.5, weight: .semibold)).tracking(0.8).foregroundStyle(.tertiary)
    }

    private func bar(fraction: Double, tone: Color, estimate: Bool, ticks: Bool) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(estimate ? Color.secondary.opacity(0.6) : tone)
                    .frame(width: max(2, geo.size.width * min(1, fraction)))
                if ticks {
                    ForEach([0.80, 0.95], id: \.self) { t in
                        Rectangle().fill(Color.primary.opacity(0.25)).frame(width: 1)
                            .offset(x: geo.size.width * t)
                    }
                }
            }
        }.frame(height: 4)
    }

    private func pill(_ t: String, soft: Bool = false, solid: Bool = false) -> some View {
        Text(t).font(.system(size: 9, weight: .heavy)).tracking(0.4)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(solid ? Color.primary : (soft ? Color.primary.opacity(0.07) : .clear),
                       in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(solid ? Color(nsColor: .windowBackgroundColor) : .secondary)
    }

    private func toneColor(_ pct: Int, estimate: Bool) -> Color {
        if estimate { return .secondary }
        return pct >= 95 ? .red : (pct >= 80 ? .orange : .primary)
    }
    private func pressureLabel(_ m: MemoryHealth) -> String {
        m.critical ? "critical" : (m.underPressure ? "warning" : "normal")
    }
    private func gb(_ bytes: UInt64) -> String {
        let g = Double(bytes) / 1_073_741_824
        return g >= 10 ? String(format: "%.0fG", g) : String(format: "%.1fG", g)
    }
    private func fmtTok(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }
    private func uptime(_ since: Date) -> String {
        let s = Int(Date().timeIntervalSince(since))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}
