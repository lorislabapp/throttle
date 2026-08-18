import SwiftUI
import AppKit
import ThrottleShared

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
    @State private var model = MultiCockpitModel.shared   // singleton: sessions outlive the window
    @State private var showInspector = false
    @State private var activeStyle = OutputStyleManager.activeName()
    @State private var hoveredSession: UUID?
    @State private var expandedFeed: UUID?
    @State private var remoteSvc = RemoteSessionsService.shared   // edge-agent sessions in the rail
    @State private var selectedRemoteID: String?  // remote session shown over the terminal area
    @State private var railFilter = ""            // rail search — shown only when crowded
    @State private var themePreset = CockpitTerminalTheme.current
    @State private var caffeine = CaffeineService.shared   // @Observable → body tracks .active (H05)
    @State private var showNotifBanner = false             // C02: notifications-denied banner
    @State private var showHealth = false                  // Throttle Health panel
    @State private var showActivity = false                // Work activity panel
    @State private var showSetup = false                   // Claude Code setup panel
    @State private var showWhatsNew = false                // What's-new / optimizations tour
    @State private var showUtilityRow = false              // Dir C reveal row (chevron)
    @State private var barWidth: CGFloat = 980             // drives narrow/icon-only collapse
    @State private var pendingModelSwitch: PendingModelSwitch?
    @State private var pendingHandoff: MissionHandoff?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct PendingModelSwitch: Identifiable {
        let id = UUID()
        let tabID: UUID
        let target: String
        let impact: PromptCacheImpact
    }

    private let hair = Color.primary.opacity(0.10)
    private let track = Color.primary.opacity(0.08)
    private var zsep: some View { Rectangle().fill(hair).frame(width: 1, height: 18) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(hair).frame(height: 1)
            globalStrip
            if model.gated { gateBanner }
            if showNotifBanner { notifDeniedBanner }
            if !model.duplicateCwds.isEmpty { duplicateBanner }
            if !model.rateLimitedSessions.isEmpty { rateLimitBanner }
            if let n = model.autoPauseCountdown { autoPauseBanner(n) }
            else if let hint = model.pacingHint { pacingBanner(hint) }
            if let loop = model.loopSessions.first { loopBanner(loop) }
            if let leak = model.leakSessions.first { leakBanner(leak) }
            HStack(spacing: 0) {
                content
                if showInspector {
                    Rectangle().fill(hair).frame(width: 1)
                    CockpitAuditInspector()
                }
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear {
            model.start(appState: appState); activeStyle = OutputStyleManager.activeName()
            if WhatsNewService.shouldShow { showWhatsNew = true }   // once per new version
        }
        .onDisappear { model.pause() }   // window close pauses the tick, never the sessions (C01)
        .onReceive(NotificationCenter.default.publisher(for: .outputStyleChanged)) { _ in
            activeStyle = OutputStyleManager.activeName()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cockpitNotificationsDenied)) { _ in
            showNotifBanner = true
        }
        .sheet(isPresented: $showHealth) { HealthCheckView().environment(appState) }
        .sheet(isPresented: $showActivity) { WorkActivityView().environment(appState) }
        .sheet(isPresented: $showSetup) { ClaudeSetupView() }
        .sheet(isPresented: $showWhatsNew) { WhatsNewView() }
        .sheet(item: $pendingHandoff) { handoff in
            MissionHandoffSheet(handoff: handoff) { confirmed in
                _ = model.continueMission(confirmed.sourceTabID, with: confirmed)
                pendingHandoff = nil
            } onCancel: {
                pendingHandoff = nil
            }
        }
        .alert(
            "Switch model and rebuild cache?",
            isPresented: Binding(
                get: { pendingModelSwitch != nil },
                set: { if !$0 { pendingModelSwitch = nil } }
            ),
            presenting: pendingModelSwitch
        ) { request in
            Button("Switch to \(request.target.capitalized)") { performModelSwitch(request) }
            Button("Cancel", role: .cancel) { pendingModelSwitch = nil }
        } message: { request in
            Text("This session's latest prompt is ≈\(fmtTok(request.impact.contextTokens)) input tokens. Claude Code caches per model, so switching now may rebuild it for ≈€\(String(format: "%.2f", request.impact.rebuildEUR)) (≈€\(String(format: "%.2f", request.impact.extraEURVersusWarm)) more than a warm read). Prefer switching after /clear or at the next task boundary.")
        }
    }

    // MARK: - Top bar (switcher + pills)

    /// Dir C — "The Reveal Row" (Claude Design 683dc5a2 · Toolbar.html). Two rows:
    /// a calm 40pt primary row (identity · view switcher · stateful toggles · status)
    /// and a 36pt utility shelf (timeline + occasional utilities) that the chevron
    /// reveals. See docs/UI-SPEC-cockpit-toolbar.md.
    private var topBar: some View {
        let narrow = barWidth < 860
        return VStack(spacing: 0) {
            primaryRow(narrow: narrow)
            utilityRow(narrow: narrow)
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: BarWidthKey.self, value: g.size.width)
        })
        .onPreferenceChange(BarWidthKey.self) { barWidth = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showUtilityRow)
    }

    private func primaryRow(narrow: Bool) -> some View {
        HStack(spacing: 6) {
            identity(compact: narrow)
            zsep
            routingMenu(compact: narrow)
            zsep
            viewSwitcher(iconsOnly: narrow)
            Spacer(minLength: 6)
            ToolbarToggle(icon: "sidebar.trailing", label: String(localized: "Audit"), isOn: showInspector,
                          iconOnly: narrow, help: String(localized: "Audit inspector")) { showInspector.toggle() }
            ToolbarToggle(icon: "terminal", label: String(localized: "Shell"), isOn: model.showShell,
                          iconOnly: narrow,
                          help: String(localized: "Side shell (⌘⇧T) — a zsh in this project's folder, beside claude")) {
                model.toggleShell()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(model.active == nil)
            zsep
            RevealChevron(isOpen: showUtilityRow) { showUtilityRow.toggle() }
            statusCluster(narrow: narrow)
        }
        .padding(.horizontal, 10).frame(height: 40)
    }

    private func routingMenu(compact: Bool) -> some View {
        Menu {
            ForEach(MissionRoutingMode.allCases) { mode in
                Button {
                    model.routingMode = mode
                } label: {
                    if model.routingMode == mode {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
                Text(mode.detail)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.runtimeForNewMission.symbol)
                if !compact { Text(model.routingMode.label) }
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String.localizedStringWithFormat(
            String(localized: "Mission routing: %@ — affects new sessions; live sessions switch through a reviewed handoff"),
            model.routingMode.label))
        .accessibilityLabel(String(localized: "Mission runtime"))
        .accessibilityValue(model.routingMode.label)
    }

    /// The revealed utility shelf: contextual timeline (or an empty note) on the
    /// left, the occasional utilities on the right. Height collapses to 0 when hidden.
    private func utilityRow(narrow: Bool) -> some View {
        HStack(spacing: 6) {
            if model.sessions.isEmpty {
                Text("No session open").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                timelineNav
            }
            Spacer(minLength: 6)
            caffeineToggle
            themeMenu
            ToolbarUtil(icon: "chart.bar.xaxis", help: String(localized: "Work activity — hours/day, projects this week")) { showActivity = true }
            ToolbarUtil(icon: "puzzlepiece.extension", help: String(localized: "Claude Code setup — MCP servers, skills, plugins")) { showSetup = true }
            ToolbarUtil(icon: "sparkles", help: String(localized: "What's new — optimization features")) { showWhatsNew = true }
            ToolbarUtil(icon: "stethoscope", help: String(localized: "Throttle Health — operational self-checks")) { showHealth = true }
        }
        .padding(.horizontal, 10)
        .frame(height: showUtilityRow ? 36 : 0)
        .background(Color.primary.opacity(0.03))
        .opacity(showUtilityRow ? 1 : 0)
        .clipped()
        .allowsHitTesting(showUtilityRow)
    }

    private func identity(compact: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary).opacity(0.88)
            if !compact {
                (Text("Throttle ").fontWeight(.semibold)
                 + Text("Cockpit").fontWeight(.medium).foregroundColor(.secondary))
                    .font(.system(size: 12.5)).fixedSize()
            }
        }
        .padding(.horizontal, 5)
    }

    private func statusCluster(narrow: Bool) -> some View {
        HStack(spacing: 7) {
            if !narrow { styleIndicator }
            if appState.isPro { pill("PRO", soft: true) }
            if appState.exactSnapshot != nil { pill("EXACT", solid: true) }
        }
        .padding(.trailing, 3)
    }

    /// Active output-style at a glance — click to open the manager (the same
    /// styles drive this Cockpit's `claude` and the terminal).
    /// Quiet, read-only status text (Dir C demotes the old capsule): the active
    /// output style as tabular mono, clickable to open the manager.
    private var styleIndicator: some View {
        Button { OutputStyleWindowController.shared.show() } label: {
            Text(styleShort(activeStyle))
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(String.localizedStringWithFormat(
            String(localized: "Output style: %@ — click to change"), activeStyle))
    }

    private func styleShort(_ s: String) -> String {
        s == "Default" ? "Default" : s.replacingOccurrences(of: "Throttle ", with: "")
    }

    /// Jump the active terminal between conversation turns (prev/next prompt or
    /// response) and back to live — a timeline for the session.
    private var timelineNav: some View {
        HStack(spacing: 2) {
            navButton("chevron.up", String(localized: "Previous turn")) { model.jumpTurn(older: true) }
            navButton("chevron.down", String(localized: "Next turn")) { model.jumpTurn(older: false) }
            navButton("arrow.down.to.line", String(localized: "Jump to live")) { model.scrollLive() }
        }
        .padding(.horizontal, 4)
        .overlay(alignment: .leading) { Rectangle().fill(hair).frame(width: 1).padding(.vertical, 6) }
        .overlay(alignment: .trailing) { Rectangle().fill(hair).frame(width: 1).padding(.vertical, 6) }
    }

    private func navButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary).frame(width: 22, height: 22).contentShape(Rectangle())
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    /// Caffeine: keep the Mac from idle-sleeping while sessions run (lid open).
    private var caffeineToggle: some View {
        let on = caffeine.active
        return Button { caffeine.toggle() } label: {
            Image(systemName: on ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(on ? String(localized: "Caffeine on — Mac won't idle-sleep while sessions run")
                 : String(localized: "Keep Mac awake while sessions run (idle only — not lid-closed)"))
        .accessibilityLabel(String(localized: "Keep Mac awake"))
        .accessibilityValue(on ? String(localized: "On") : String(localized: "Off"))
    }

    /// Curated terminal presets (no full editor — that's a non-goal). Switching
    /// re-styles every live session immediately.
    private var themeMenu: some View {
        Menu {
            ForEach(CockpitTerminalTheme.Preset.allCases) { p in
                Button {
                    CockpitTerminalTheme.current = p
                    themePreset = p
                    model.restyleTerminals()
                } label: {
                    if themePreset == p { Label(p.label, systemImage: "checkmark") } else { Text(p.label) }
                }
            }
        } label: {
            Image(systemName: "paintpalette").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(String.localizedStringWithFormat(String(localized: "Terminal theme: %@"), themePreset.label))
        .accessibilityLabel(String(localized: "Terminal theme")).accessibilityValue(themePreset.label)
    }

    /// The dominant control: a segmented view switcher on a recessed track, icon +
    /// label (icon-only when narrow), active item raised onto an elevated surface.
    private func viewSwitcher(iconsOnly: Bool) -> some View {
        HStack(spacing: 1) {
            ForEach(MultiCockpitModel.ViewMode.allCases) { mode in
                SwitcherItem(icon: viewIcon(mode), label: mode.label,
                             isOn: model.viewMode == mode, iconOnly: iconsOnly) {
                    model.viewMode = mode
                }
            }
        }
        .padding(2)
        .background(track, in: RoundedRectangle(cornerRadius: 8))
    }

    private func viewIcon(_ m: MultiCockpitModel.ViewMode) -> String {
        switch m {
        case .dashboard: return "square.grid.2x2"
        case .tabs:      return "macwindow"
        case .rail:      return "sidebar.left"
        case .mission:   return "rectangle.3.group"
        case .portfolio: return "point.3.filled.connected.trianglepath.dotted"
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
                    Text("\(b.name)\nresets \(b.reset)\(b.resetInSeconds.map { " · in \(MultiCockpitModel.countdown($0))" } ?? "")")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
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
            HStack(spacing: 6) {
                gLabel("MACHINE")
                // Quiet mode: Throttle backs off its own scans under memory pressure.
                // Graphite tag, no pressure colour (memory ≠ cap pressure).
                if MemoryPressureMonitor.shared.isQuiet {
                    Text("quiet").font(.system(size: 8.5, weight: .semibold)).textCase(.lowercase).foregroundStyle(.tertiary)
                        .padding(.horizontal, 4).padding(.vertical, 1).overlay(Capsule().strokeBorder(hair, lineWidth: 1))
                        .help("Memory pressure — Throttle paused its background scans to free RAM")
                }
            }
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

    /// The loop detector flagged a session cycling the same action with no file
    /// changes — likely a runaway "Ralph Wiggum" loop burning tokens. Advisory:
    /// offers the (already-shipped) Pause; never auto-pauses.
    @ViewBuilder
    private func loopBanner(_ s: CockpitTab) -> some View {
        if let sig = s.loopSignal {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12)).foregroundStyle(.orange)
                Text("\(s.projectName): possible runaway loop — \(sig.repeatedTool) ×\(sig.repeats), no file changes\(sig.tokensBurned > 0 ? " · ≈\(fmtTok(sig.tokensBurned)) tok burned" : "").")
                    .font(.system(size: 11.5)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 0)
                if s.isSpawned {
                    Button(s.isPaused ? "Resume" : "Pause") { s.isPaused ? s.resumeProcess() : s.pauseProcess() }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.accentColor)
                }
                Button { s.loopSignal = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.orange.opacity(0.10))
        }
    }

    /// A session's node subtree has ballooned (leak #4953). Offer a restart-in-place
    /// that reclaims the leaked heap while keeping context via --resume. Advisory.
    private func leakBanner(_ s: CockpitTab) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "memorychip").font(.system(size: 12)).foregroundStyle(.orange)
            Text("\(s.projectName): \(s.resourceReason ?? "sampled resource pressure") at \(ByteCountFormatter.string(fromByteCount: Int64(s.ramBytes), countStyle: .memory)), \(Int(s.cpuPercent.rounded()))% CPU. Restart reclaims RAM, but resume may rebuild \(resumeImpactText(s) ?? "the prompt cache").")
                .font(.system(size: 11.5)).foregroundStyle(.primary).lineLimit(1)
            Spacer(minLength: 0)
            Button("Restart") { s.restartInPlace() }
                .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.accentColor)
            Button { s.leakSuspected = false } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    /// One or more sessions hit the account usage cap. Account limits are shared
    /// across every session, so this flags WHICH are blocked + the soonest reset.
    private var rateLimitBanner: some View {
        let blocked = model.rateLimitedSessions
        let names = blocked.map(\.projectName).joined(separator: ", ")
        let eta = model.soonestRateLimitReset.map { MultiCockpitModel.countdown(Int64($0.timeIntervalSinceNow)) }
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 12)).foregroundStyle(.red)
            Text(blocked.count == 1
                 ? "\(names) hit the usage limit\(eta.map { " — frees up in \($0)" } ?? "")."
                 : "\(blocked.count) sessions rate-limited (\(names))\(eta.map { " — soonest frees up in \($0)" } ?? "").")
                .font(.system(size: 11.5)).foregroundStyle(.primary).lineLimit(1)
            Spacer(minLength: 0)
            if let first = blocked.first {
                if first.runtime == .claudeCode {
                    Button("Continue with Codex") { requestHandoff(first, to: .codex) }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.accentColor)
                }
                Button("Show") { model.wake(first.id) }
                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.red.opacity(0.10))
    }

    /// Soft pacing tier (below auto-pause): several sessions burning toward the
    /// shared cap. Informational + a one-tap "Pause idle" convenience; never acts
    /// on its own. Suppressed while the auto-pause countdown is showing.
    private func pacingBanner(_ hint: MultiCockpitModel.PacingHint) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.needle").font(.system(size: 12)).foregroundStyle(.orange)
            Text("\(hint.burning) sessions burning — ≈\(hint.etaText) to your cap.")
                .font(.system(size: 11.5)).foregroundStyle(.primary).lineLimit(1)
            Spacer(minLength: 0)
            Button("Pause idle") { model.pauseIdleSessions() }
                .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.accentColor)
            Button { model.pacingHint = nil } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    /// Auto-pause ACT armed: binding ≥97% + imminent wall. Cancelable countdown
    /// before a reversible SIGSTOP of the live sessions. Opt-in; never a kill.
    private func autoPauseBanner(_ seconds: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill").font(.system(size: 12)).foregroundStyle(.orange)
            Text("Near the usage cap — auto-pausing live sessions in \(seconds)s to save your quota.")
                .font(.system(size: 11.5)).foregroundStyle(.primary).lineLimit(1)
            Spacer(minLength: 0)
            Button("Cancel") { model.cancelAutoPause() }
                .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.accentColor)
                .help("Keep running — don't pause. (You can also disable auto-pause in Settings.)")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    /// Same project open in >1 live session = wasted RAM + tokens. Offer a
    /// 1-click consolidate (hibernate the extras, keep the most-recent; resume-id
    /// preserved → nothing lost).
    private var duplicateBanner: some View {
        let names = model.duplicateCwds
            .map { cwd in (cwd as NSString).lastPathComponent }
            .sorted().joined(separator: ", ")
        return HStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle").font(.system(size: 12)).foregroundStyle(.orange)
            Text("Same project open twice: \(names) — wasting RAM + tokens.")
                .font(.system(size: 11.5)).foregroundStyle(.primary)
            Spacer(minLength: 0)
            Button("Consolidate") { model.consolidateDuplicates() }
                .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.accentColor)
                .help("Hibernate the extra session(s), keep the most recent — nothing lost")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    /// Shown when a hidden session needed you but notifications are off (C02) —
    /// so the "never lose a background prompt" promise degrades visibly.
    private var notifDeniedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.slash.fill").font(.system(size: 12)).foregroundStyle(.orange)
            Text("A background session needs you, but notifications are off.")
                .font(.system(size: 11.5)).foregroundStyle(.primary)
            Spacer(minLength: 0)
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                    NSWorkspace.shared.open(url)
                }
            }.buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.accentColor)
            Button { showNotifBanner = false } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: - Content (the active layout)

    @ViewBuilder
    private var content: some View {
        if model.viewMode == .dashboard {
            // The cover page — stats work even with no live session.
            CockpitDashboardView(machine: model.machine).environment(appState)
        } else if model.viewMode == .portfolio {
            // Obsidian-style map of the whole ~/GitHub portfolio: what's duplicated
            // (code) and re-researched (deep-research topics) across apps.
            PortfolioGraphView()
        } else if model.sessions.isEmpty {
            emptyState
        } else {
            switch model.viewMode {
            case .tabs:    tabsLayout
            case .rail:    railLayout
            case .mission: missionLayout
            case .dashboard, .portfolio: EmptyView()   // handled above
            }
        }
    }

    private var terminal: some View {
        // MultiTerminalStack stays the STABLE first child of a single HSplitView in
        // both states — never swapped between view-tree branches. Toggling the shell
        // only adds/removes the second pane, so the claude terminals' NSView container
        // is never destroyed/recreated (which produced the black screen on toggle-off).
        HSplitView {
            MultiTerminalStack(sessions: model.sessions, activeID: model.activeID)
                .frame(minWidth: 340)
            if model.showShell, let active = model.active {
                ShellPane(tab: active)
                    .frame(minWidth: 280)
                    .id(active.id)   // re-mount the shell host when the active tab changes
            }
        }
        .background(Color(nsColor: CockpitTerminalTheme.backgroundColor))
        // A selected remote session OVERLAYS the local terminals (same stability
        // rule: the local NSViews underneath are never torn down). Waking any
        // local session drops back to it.
        .overlay {
            if let rid = selectedRemoteID,
               let rs = remoteSvc.sessions.first(where: { $0.id == rid }) {
                RemoteSessionPane(session: rs, onClose: { selectedRemoteID = nil })
                    .id(rid)   // fresh attach when switching between remote sessions
            }
        }
        .onChange(of: model.activeID) { selectedRemoteID = nil }
        .onAppear { if remoteSvc.isConfigured { remoteSvc.startPolling() } }
    }

    // MARK: A — Tab bar

    private var tabsLayout: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(model.sessions) { s in
                        let on = s.id == (model.active?.id)
                        Button { model.wake(s.id) } label: {
                            HStack(spacing: 8) {
                                stateDot(s).help(stateDotHelp(s))
                                Text(s.projectName).font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(on ? .primary : .secondary)
                                runtimeTag(s.runtime)
                                if s.needsInput {
                                    Image(systemName: "bell.badge.fill").font(.system(size: 10))
                                        .foregroundStyle(.orange)
                                }
                                if let e = s.eur {
                                    Text(String(format: "€%.2f", e))
                                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                }
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
        newSessionMenu(gated: model.gated) {
            Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 12).frame(minHeight: 40).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(model.gated ? "Mac saturated" : "New session")
    }

    private func runtimeTag(_ runtime: AgentRuntime) -> some View {
        Text(runtime.shortLabel.uppercased())
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .foregroundStyle(runtime == .claudeCode ? Color.orange : Color.accentColor)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel(runtime.label)
    }

    // MARK: B — Project rail

    private var railLayout: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    gLabel("SESSIONS · \(model.sessions.count)")
                    Spacer()
                    if model.waitingCount > 0 { waitingChip(model.waitingCount) }
                    sortMenu
                }.padding(.horizontal, 13).padding(.vertical, 9)
                // Search only appears once the rail is crowded — no permanent chrome
                // for the common few-session case.
                if model.sessions.count > 6 { railSearchField }
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(filteredSessions) { s in railRow(s) }
                        if filteredSessions.isEmpty, !railFilter.isEmpty {
                            Text("No session matches “\(railFilter)”.")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                                .padding(.vertical, 12)
                        }
                        // Edge-agent sessions live on the user's box, not this Mac.
                        // A remote OWNED by a local tab (offloaded from it) is NOT
                        // listed here — its local row wears the REMOTE badge
                        // instead, so one session never shows as two rows. Only
                        // orphan remotes (started from the sheet / another device)
                        // appear in this section.
                        if remoteSvc.isConfigured,
                           !orphanRemotes.isEmpty || remoteSvc.offloadStatus != nil {
                            HStack {
                                gLabel("REMOTE · \(orphanRemotes.count)")
                                Spacer()
                            }.padding(.horizontal, 5).padding(.top, 10).padding(.bottom, 2)
                            if let st = remoteSvc.offloadStatus {
                                Text(st).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 5).padding(.bottom, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            ForEach(orphanRemotes) { rs in remoteRailRow(rs) }
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 4)
                }
                Spacer(minLength: 0)
                Rectangle().fill(hair).frame(height: 1)
                newSessionMenu(gated: model.gated) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                        Text("New session").font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11).padding(.vertical, 9).contentShape(Rectangle())
                }.menuStyle(.borderlessButton)
            }
            .frame(width: 234)
            .overlay(alignment: .trailing) { Rectangle().fill(hair).frame(width: 1) }
            terminal
        }
    }

    /// Sort the session rail (last activity, cost, memory, name, waiting-first,
    /// or manual drag order). Drag-reorder stays available in Manual mode.
    private var sortMenu: some View {
        Menu {
            ForEach(MultiCockpitModel.SortMode.allCases) { mode in
                Button {
                    model.sortMode = mode
                } label: {
                    if model.sortMode == mode { Label(mode.label, systemImage: "checkmark") }
                    else { Text(mode.label) }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(String.localizedStringWithFormat(String(localized: "Sort sessions: %@"), model.sortMode.label))
        .accessibilityLabel(String(localized: "Sort sessions")).accessibilityValue(model.sortMode.label)
    }

    /// Sessions after the rail filter — case-insensitive substring on project name.
    private var filteredSessions: [CockpitTab] {
        let q = railFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.displaySessions }
        return model.displaySessions.filter { $0.projectName.lowercased().contains(q) }
    }

    private var railSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            TextField("Filter sessions", text: $railFilter)
                .textFieldStyle(.plain).font(.system(size: 12))
            if !railFilter.isEmpty {
                Button { railFilter = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.tertiary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10).padding(.bottom, 4)
    }

    /// The per-session action menu — the "decision layer" surfaced as one right-click:
    /// switch model (cheap task → Haiku), offload to the server, freeze/close. Shared
    /// by the row's right-click context menu AND the ⋯ hover button so the actions are
    /// discoverable, not hidden behind a right-click only power users try.
    @ViewBuilder private func sessionMenu(_ s: CockpitTab) -> some View {
        let target: AgentRuntime = s.runtime == .claudeCode ? .codex : .claudeCode
        Button {
            requestHandoff(s, to: target)
        } label: {
            Label("Continue mission with \(target.label)", systemImage: "arrow.left.arrow.right")
        }
        Divider()
        if s.isSpawned {
            Menu("Switch Claude model") {
                Button("Fable")  { requestModelSwitch(s, to: "fable") }
                Button("Opus")   { requestModelSwitch(s, to: "opus") }
                Button("Sonnet") { requestModelSwitch(s, to: "sonnet") }
                Button("Haiku")  { requestModelSwitch(s, to: "haiku") }
            }
            .disabled(s.runtime != .claudeCode)
        }
        // One-click offload of THIS session. The menu always says what will
        // actually happen: not configured → open setup; already on the box → show
        // it / bring it back / stop it; otherwise → upload + resume, no sheet.
        if !remoteSvc.isConfigured {
            Button("Offload to server — set up…") { SessionOffloadWindowController.shared.show() }
        } else if let rid = s.offloadedRemoteID, remoteSvc.sessions.contains(where: { $0.id == rid }) {
            Button("Show remote session") { selectedRemoteID = rid }
            Button("Bring back to Mac") { bringBack(s) }
            Button("Stop remote session") {
                Task {
                    await remoteSvc.act(rid, "stop")
                    s.offloadedRemoteID = nil
                    if selectedRemoteID == rid { selectedRemoteID = nil }
                }
            }
        } else {
            Button("Offload to server (with context)") { offloadTab(s) }
        }
        Button("Server settings…") { SessionOffloadWindowController.shared.show() }
        Divider()
        if s.isSpawned {
            Button(s.isPaused ? "Resume" : "Pause") { s.isPaused ? s.resumeProcess() : s.pauseProcess() }
            Button(hibernateActionLabel(s)) { model.hibernate(s.id) }
        }
        Button("Project stats + optimizer") {
            ProjectWindowController.shared.show(appState: appState, projectID: MultiCockpitModel.claudeProjectDirName(s.cwd))
        }
        Divider()
        Button("Close session", role: .destructive) { model.close(s.id) }
    }

    private func requestHandoff(_ session: CockpitTab, to target: AgentRuntime) {
        let sourceTabID = session.id
        let missionID = session.missionID
        let projectName = session.projectName
        let cwd = session.cwd
        let source = session.runtime
        let sourceSessionID = session.sessionId ?? (session.runtime == .claudeCode
            ? MultiCockpitModel.newestSession(cwd: cwd, since: .distantPast)?.id
            : MissionRuntimeService.newestCodexSession(cwd: cwd, since: .distantPast)?.id)
        Task {
            let snapshot = await Task.detached(priority: .utility) {
                let git = MissionRuntimeService.gitEvidence(at: cwd)
                let conversation = MissionRuntimeService.portableConversationContext(
                    runtime: source, sessionID: sourceSessionID, cwd: cwd
                )
                let capabilities = MissionRuntimeService.capabilityCompatibility(
                    source: source, target: target, cwd: cwd
                )
                return (git, conversation, capabilities)
            }.value
            pendingHandoff = MissionHandoff(
                sourceTabID: sourceTabID,
                missionID: missionID,
                projectName: projectName,
                cwd: cwd,
                source: source,
                target: target,
                sourceSessionID: sourceSessionID,
                objective: "Continue the current work at the next unfinished task.",
                context: MissionHandoffContext(
                    completed: "", remaining: "", validation: "", blockers: "",
                    recentConversation: snapshot.1
                ),
                capabilities: snapshot.2,
                git: snapshot.0
            )
        }
    }

    private func requestModelSwitch(_ session: CockpitTab, to target: String) {
        if session.promptCacheImpact?.model.lowercased().contains(target.lowercased()) == true {
            return // Already on this model: avoid a no-op command and needless warning.
        }
        guard let impact = session.promptCacheImpact, impact.shouldWarn else {
            session.confirmedModelSwitchTarget = target
            session.terminal?.send(txt: "/model \(target)\n")
            return
        }
        pendingModelSwitch = PendingModelSwitch(
            tabID: session.id,
            target: target,
            impact: PromptCacheImpactService.repriced(impact, for: target)
        )
    }

    private func performModelSwitch(_ request: PendingModelSwitch) {
        if let session = model.sessions.first(where: { $0.id == request.tabID }) {
            session.confirmedModelSwitchTarget = request.target
            session.terminal?.send(txt: "/model \(request.target)\n")
        }
        pendingModelSwitch = nil
    }

    private func hibernateActionLabel(_ session: CockpitTab) -> String {
        guard let impact = session.promptCacheImpact, impact.shouldWarn else {
            return "Hibernate — free RAM, keep context"
        }
        return "Hibernate — resume may reload ≈\(fmtTok(impact.contextTokens)) input (≈€\(String(format: "%.2f", impact.rebuildEUR)))"
    }

    private func resumeImpactText(_ session: CockpitTab) -> String? {
        guard let impact = session.promptCacheImpact, impact.shouldWarn else { return nil }
        return "≈\(fmtTok(impact.contextTokens)) input · ≈€\(String(format: "%.2f", impact.rebuildEUR))"
    }

    /// One icon button in the rail-row hover cluster.
    private func railAction(_ icon: String, _ size: CGFloat, _ color: Color, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size)).foregroundStyle(color)
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    /// Direct offload from the decision menu: resolve the tab's transcript, ship
    /// it, resume on the box, then select the new remote session so the user SEES
    /// where it went (rail REMOTE badge + attached terminal).
    private func offloadTab(_ s: CockpitTab) {
        // The tab may not know its claude session id until claude writes the
        // transcript — fall back to the newest JSONL for the cwd.
        let sid = s.sessionId ?? MultiCockpitModel.newestSession(cwd: s.cwd, since: .distantPast)?.id
        guard let sid else {
            remoteSvc.offloadStatus = "No transcript yet for \(s.projectName) — say something to claude first."
            return
        }
        let cwd = s.cwd, project = s.projectName
        Task {
            if let rid = await remoteSvc.offloadTab(sessionId: sid, localCwd: cwd, projectName: project) {
                s.offloadedRemoteID = rid
                // MOVE semantics, not copy: hibernate the local twin (context kept,
                // RAM freed — the whole point of offloading on a 16 GB Mac). The
                // local row stays in the rail wearing the REMOTE badge; "Bring back
                // to Mac" reverses the whole thing.
                model.hibernate(s.id)
                selectedRemoteID = rid
            }
        }
    }

    /// Reverse offload: transcript comes home, remote stops, the hibernated local
    /// tab respawns with `--resume` on the freshest context.
    private func bringBack(_ s: CockpitTab) {
        guard let rid = s.offloadedRemoteID else { return }
        Task {
            if let sid = await remoteSvc.bringBack(remoteID: rid, localCwd: s.cwd) {
                s.offloadedRemoteID = nil
                if !s.isHibernated && s.isSpawned { model.hibernate(s.id) }  // force a respawn on the new id
                s.sessionId = sid
                selectedRemoteID = nil
                model.wake(s.id)
            }
        }
    }

    /// Remote sessions NOT owned by any local tab (started from the sheet or
    /// another device). Owned ones are represented by their local row's badge.
    private var orphanRemotes: [EdgeAgentService.RemoteSession] {
        remoteSvc.sessions.filter { rs in
            !model.sessions.contains { $0.offloadedRemoteID == rs.id }
        }
    }

    /// Rail row for a session running on the edge box. Deliberately lighter than
    /// the local rows (no RAM bar, no question feed — the box owns those), with an
    /// unmissable REMOTE badge answering "is this on my Mac or the server?".
    private func remoteRailRow(_ rs: EdgeAgentService.RemoteSession) -> some View {
        let on = rs.id == selectedRemoteID
        return Button { selectedRemoteID = rs.id } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Circle().fill(rs.state == "working" ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(rs.project).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(on ? .primary : .secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    remoteChip
                }
                HStack(spacing: 8) {
                    if let m = rs.model { modelChip(m) }
                    if let t = rs.tokens, t > 0 {
                        Text(fmtTok(t)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Text(rs.state).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay { if on { RoundedRectangle(cornerRadius: 9).stroke(hair, lineWidth: 1) } }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityLabel(String.localizedStringWithFormat(
            String(localized: "Remote session %@, %@"), rs.project, rs.state))
        .contextMenu {
            Button("Pause") { Task { await remoteSvc.act(rs.id, "pause") } }
            Button("Resume") { Task { await remoteSvc.act(rs.id, "resume") } }
            Divider()
            Button("Stop session") {
                Task {
                    await remoteSvc.act(rs.id, "stop")
                    if selectedRemoteID == rs.id { selectedRemoteID = nil }
                }
            }
        }
    }

    private var remoteChip: some View {
        Text("REMOTE")
            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
            .padding(.horizontal, 4.5).padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(Color.accentColor)
    }

    private func railRow(_ s: CockpitTab) -> some View {
        let on = s.id == model.active?.id
        // Offloaded-and-alive tabs open their REMOTE terminal, not the (hibernated)
        // local one — one row, one session, wherever it currently runs.
        let liveRemoteID = s.offloadedRemoteID.flatMap { rid in
            remoteSvc.sessions.contains(where: { $0.id == rid }) ? rid : nil
        }
        return Button {
            if let rid = liveRemoteID { selectedRemoteID = rid } else { model.wake(s.id) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    stateDot(s).help(stateDotHelp(s))
                    Text(s.projectName).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(on ? .primary : .secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if liveRemoteID != nil { remoteChip }
                    else if s.isHibernated { hibernatedChip }
                    else if s.needsInput { waitingChip() }
                    if let model = s.model { modelChip(model) }
                }
                if s.needsInput, let q = s.latestQuestion {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "arrow.turn.down.left").font(.system(size: 9, weight: .semibold))
                        Text(q).font(.system(size: 10.5)).lineLimit(2)
                    }.foregroundStyle(.orange)
                }
                sessionDiagnostics(s)
                questionFeed(s)
                sessionMetricsRow(s)
                sessionResourceRow(s)
            }
            .padding(.horizontal, 10).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay { if on { RoundedRectangle(cornerRadius: 9).stroke(hair, lineWidth: 1) } }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(railRowA11yLabel(s))
        .accessibilityAddTraits(s.id == model.active?.id ? [.isButton, .isSelected] : .isButton)
        .contextMenu { sessionMenu(s) }
        .overlay(alignment: .topTrailing) {
            if hoveredSession == s.id {
                // Solid floating cluster so it OCCLUDES the model badge underneath
                // instead of overlapping it (per-button circles left gaps).
                HStack(spacing: 9) {
                    railAction("chart.bar.doc.horizontal", 11.5, .secondary, "Project stats + CLAUDE.md optimizer") {
                        ProjectWindowController.shared.show(appState: appState, projectID: MultiCockpitModel.claudeProjectDirName(s.cwd))
                    }
                    if s.isSpawned {
                        railAction(s.isPaused ? "play.fill" : "pause.fill", 11, s.isPaused ? .purple : .secondary,
                                   s.isPaused ? "Resume — unfreeze this session" : "Pause — freeze this session (keeps state)") {
                            s.isPaused ? s.resumeProcess() : s.pauseProcess()
                        }
                        railAction("moon.zzz.fill", 12, .secondary, hibernateActionLabel(s)) { model.hibernate(s.id) }
                    }
                    railAction("xmark.circle.fill", 13, .secondary, "Close session") { model.close(s.id) }
                    // ⋯ opens the full decision menu — makes the right-click actions
                    // (model switch, offload) discoverable to non-power users.
                    Menu {
                        sessionMenu(s)
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary).frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("More actions — switch model, offload to server…")
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(hair, lineWidth: 0.5))
                .padding(5)
            }
        }
        .onHover { hoveredSession = $0 ? s.id : nil }
        .draggable(s.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let str = items.first, let dragged = UUID(uuidString: str) else { return false }
            model.move(dragged: dragged, onto: s.id)
            return true
        }
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
        return Button { model.wake(s.id); model.viewMode = .rail } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    stateDot(s).help(stateDotHelp(s))
                    Text(s.projectName).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 0)
                    if s.needsInput { waitingChip() }
                    if let m = s.model { modelChip(m) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.eur.map { String(format: "€%.2f", $0) } ?? "—")
                        .font(.system(size: 19, design: .monospaced)).foregroundStyle(.primary)
                    if let t = s.tokens, t > 0 {
                        Text("\(fmtTok(t)) tokens this session").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    } else if let started = s.spawnedAt {
                        Text("up \(uptime(started))").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    } else {
                        Text("dormant").font(.system(size: 10.5)).foregroundStyle(.quaternary)
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    HStack(spacing: 1) {
                        Text("Focus terminal").font(.system(size: 10))
                        Image(systemName: "chevron.right").font(.system(size: 7, weight: .semibold))
                    }.foregroundStyle(.tertiary)
                    Spacer()
                    if s.ramBytes > 0 {
                        Text("\(gb(s.ramBytes)) RAM").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary)
                    }
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
        newSessionMenu(gated: model.gated) {
            VStack(spacing: 7) {
                Image(systemName: "plus").font(.system(size: 18, weight: .medium))
                Text("New session").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, minHeight: 128)
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(hair, style: StrokeStyle(lineWidth: 1, dash: [4, 4])) }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }.menuStyle(.borderlessButton)
    }

    // MARK: - Empty + picker

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "square.split.2x2").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("No sessions running").font(.system(size: 15, weight: .semibold)).padding(.top, 16)
            Text("Start your first coding-agent mission — Throttle keeps its runtime, handoffs and machine load in view as you work.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 320).padding(.top, 6)
            newSessionMenu(gated: false) {
                HStack(spacing: 8) { Image(systemName: "plus"); Text("Start a session") }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9))
            }.menuStyle(.borderlessButton).fixedSize().padding(.top, 18)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Native dropdown anchored to its trigger (no random floating popup):
    /// recent projects + "Open other folder…" (a real NSOpenPanel for new
    /// projects). `gated` disables it under memory pressure — except the very
    /// first session, which is always allowed.
    private func newSessionMenu<L: View>(gated: Bool, @ViewBuilder label: () -> L) -> some View {
        Menu {
            let projects = model.recentProjects()
            if projects.isEmpty {
                Text("No recent projects")
            } else {
                Section("Recent projects") {
                    ForEach(projects) { p in
                        Button { open(p.name, p.cwd) } label: { Label(p.name, systemImage: "folder") }
                    }
                }
            }
            Divider()
            Button { open("Home", FileManager.default.homeDirectoryForCurrentUser.path) } label: {
                Label("Scratch session (Home)", systemImage: "house")
            }
            Button { openFolderPanel() } label: { Label("Open other folder…", systemImage: "folder.badge.plus") }
        } label: { label() }
        .menuIndicator(.hidden)
        // NOTE: intentionally NOT .disabled(gated). On a memory-constrained Mac
        // the saturation gate can be true ~permanently — disabling the button
        // outright leaves a dead "New session" control. Instead we keep it
        // clickable and confirm before opening when saturated (see `open`).
    }

    private func open(_ name: String, _ cwd: String) {
        if model.gated, !confirmOpenUnderPressure() { return }

        if let existing = model.sessions(inProjectAt: cwd).first {
            switch confirmDuplicateProject(name: name, count: model.sessions(inProjectAt: cwd).count) {
            case .focusExisting:
                selectedRemoteID = nil
                model.focusSession(existing.id)
                if model.viewMode == .mission { model.viewMode = .rail }
                return
            case .openAnother:
                break
            case .cancel:
                return
            }
        }

        guard let runtime = chooseRuntimeForNewSession() else { return }
        model.newSession(projectName: name, cwd: cwd, runtime: runtime)
        if model.viewMode == .mission { model.viewMode = .rail }
    }

    private enum DuplicateProjectChoice {
        case focusExisting, openAnother, cancel
    }

    private func confirmDuplicateProject(name: String, count: Int) -> DuplicateProjectChoice {
        let alert = NSAlert()
        alert.messageText = "A tab for \(name) is already open"
        alert.informativeText = count == 1
            ? "Go to the existing tab, or intentionally open another agent session for the same project?"
            : "\(count) tabs already use this project. Go to the most recently active one, or intentionally open another?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Go to Existing Tab")
        alert.addButton(withTitle: "Open Anyway")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .focusExisting
        case .alertSecondButtonReturn: return .openAnother
        default: return .cancel
        }
    }

    private func chooseRuntimeForNewSession() -> AgentRuntime? {
        let recommended = model.runtimeForNewMission
        let alternative: AgentRuntime = recommended == .claudeCode ? .codex : .claudeCode
        let alert = NSAlert()
        alert.messageText = "Start with Claude Code or Codex?"
        alert.informativeText = "Choose the coding agent for this new tab. You can switch later through a reviewed context handoff."
        alert.alertStyle = .informational
        alert.addButton(withTitle: recommended.label)
        alert.addButton(withTitle: alternative.label)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return recommended
        case .alertSecondButtonReturn: return alternative
        default: return nil
        }
    }

    /// Saturation is advisory, not a hard block — it's the user's Mac. Warn
    /// once, let them decide.
    private func confirmOpenUnderPressure() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Your Mac is low on memory"
        alert.informativeText = "Throttle detects heavy memory pressure (swap is high). Opening another agent session may cause significant swapping and slow everything down.\n\nOpen it anyway?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Anyway")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        // No manual makeKeyAndOrderFront here: runModal orders the window itself,
        // and ordering it early fires windowWillOrderOnScreen into the NSOpenPanel's
        // still-live NSRemoteView observer, which throws on macOS 27 (SIGABRT).
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func openFolderPanel() {
        // Run after the SwiftUI Menu has fully dismissed, and activate the app
        // first — otherwise (esp. as a menu-bar/accessory app under memory
        // pressure) the panel can open behind the window and look like a no-op.
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true   // adds the "New Folder" button → start a brand-new project
            panel.prompt = "Open Session"
            panel.message = "Choose or create a project folder to start a Claude Code or Codex session in."
            NSApp.activate(ignoringOtherApps: true)
            // Pas de makeKeyAndOrderFront manuel : runModal ordonne le panel lui-même.
            // L'ordonner tôt fait poster windowWillOrderOnScreen dans le NSRemoteView
            // out-of-process du panel → SIGABRT sur macOS 26/27 (même bug que l'alerte).
            if panel.runModal() == .OK, let url = panel.url {
                // Next runloop: let the panel's remote view finish tearing down
                // before any window we order (pressure alert, cockpit) posts
                // windowWillOrderOnScreen at it — it throws on macOS 27.
                DispatchQueue.main.async {
                    open(url.lastPathComponent, url.path)
                }
            }
        }
    }

    // MARK: - Bits

    /// Rich session-state dot: green=claude working (or you typing), orange ring=
    /// claude answered & waiting for you, gray=idle at prompt, hollow=dormant/
    /// hibernated. Replaces the binary live/gray flicker.
    @ViewBuilder
    private func stateDot(_ s: CockpitTab) -> some View {
        switch s.state {
        case .working:
            Circle().fill(Color.green).frame(width: 6, height: 6)
        case .rateLimited:
            Circle().fill(Color.red).frame(width: 6, height: 6)
        case .paused:
            Image(systemName: "pause.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(.purple)
                .frame(width: 7, height: 7)
        case .waiting:
            Circle().strokeBorder(Color.orange, lineWidth: 1.5).frame(width: 7, height: 7)
        case .idle:
            Circle().fill(Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
        case .dormant, .hibernated:
            Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1).frame(width: 6, height: 6)
        }
    }

    private func stateDotHelp(_ s: CockpitTab) -> String {
        switch s.state {
        case .working:    return "Working"
        case .paused:     return s.autoPaused
            ? "Auto-paused (crowded) — focus this tab to resume instantly, 0 tokens"
            : "Paused (frozen) — click ▶ to resume"
        case .rateLimited:
            let when = s.rateLimitedUntil.map { " — frees up in \(MultiCockpitModel.countdown(Int64($0.timeIntervalSinceNow)))" } ?? ""
            return "Rate-limited\(when)"
        case .waiting:    return "Claude answered — waiting for you"
        case .idle:       return "Idle (at prompt)"
        case .dormant:    return "Not started"
        case .hibernated: return "Hibernated"
        }
    }

    /// Per-session question history — the "don't lose the question" feed.
    /// Shown whenever claude has asked anything this session (even after you've
    /// answered), collapsed to a count; tap to expand the full list with times.
    @ViewBuilder
    private func questionFeed(_ s: CockpitTab) -> some View {
        let qs = s.questions
        if !qs.isEmpty {
            let open = expandedFeed == s.id
            Button { expandedFeed = open ? nil : s.id } label: {
                HStack(spacing: 4) {
                    Image(systemName: "questionmark.bubble").font(.system(size: 9))
                    Text("\(qs.count) question\(qs.count == 1 ? "" : "s")")
                        .font(.system(size: 9.5, weight: .medium))
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(.tertiary).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(qs.reversed()) { q in
                        HStack(alignment: .top, spacing: 6) {
                            Text(uptime(q.at)).font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary).frame(width: 30, alignment: .trailing)
                            Text(q.text).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
                .padding(.leading, 2).padding(.top, 2)
            }
        }
    }

    /// "waiting" badge — claude is blocked on a question in this session. Orange
    /// is earned here: it's a real action-required state. Optional count for the
    /// header rollup.
    private func waitingChip(_ count: Int = 0) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "bell.badge.fill").font(.system(size: 8.5, weight: .semibold))
            Text(count > 0 ? "\(count) waiting" : "waiting").font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Color.orange.opacity(0.12), in: Capsule())
    }

    /// One spoken label per rail row — surfaces the waiting/attention state that
    /// was conveyed only by an orange dot before (C03; the feature's differentiator).
    private func railRowA11yLabel(_ s: CockpitTab) -> String {
        var parts = [s.projectName]
        if s.needsInput { parts.append("waiting for your input") }
        if s.isHibernated { parts.append("hibernated") }
        if let issue = s.resumeIssue { parts.append(issue) }
        if let reason = s.resourceReason { parts.append(reason) }
        if let m = s.model { parts.append(m) }
        if let e = s.eur { parts.append(String(format: "%.2f euros", e)) }
        return parts.joined(separator: ", ")
    }

    private func resourceColor(_ session: CockpitTab) -> Color {
        switch session.resourceState {
        case .healthy: return .secondary
        case .constrained: return .orange
        case .critical: return .red
        }
    }

    private func codexProgressText(_ progress: CodexProgressSnapshot) -> String {
        guard progress.commandsCompleted > 0 else { return progress.title }
        return progress.title + " · " + String(progress.commandsCompleted) + " events"
    }

    @ViewBuilder
    private func sessionDiagnostics(_ session: CockpitTab) -> some View {
        if let issue = session.resumeIssue {
            Label(issue, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
        if let progress = session.codexProgress {
            Text(codexProgressText(progress))
                .font(.system(size: 10.5))
                .foregroundStyle(progress.phase == .failed ? Color.red : Color.secondary)
                .lineLimit(1)
        }
    }

    private func sessionMetricsRow(_ session: CockpitTab) -> some View {
        HStack(spacing: 8) {
            if let euros = session.eur {
                Text(String(format: "€%.2f", euros))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let tokens = session.tokens, tokens > 0 {
                Text(fmtTok(tokens))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if session.isHibernated, let resume = resumeImpactText(session) {
                Text("resume \(resume)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            if let started = session.spawnedAt {
                Text("up \(uptime(started))").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            } else {
                Text("dormant").font(.system(size: 10.5)).foregroundStyle(.quaternary)
            }
        }
    }

    @ViewBuilder
    private func sessionResourceRow(_ session: CockpitTab) -> some View {
        if session.ramBytes > 0 {
            HStack(spacing: 5) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(track)
                        Capsule().fill(resourceColor(session).opacity(0.65))
                            .frame(width: max(2, geometry.size.width * ramFraction(session.ramBytes)))
                    }
                }
                .frame(height: 3)
                Text(resourceSummary(session))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(resourceTextColor(session))
            }
        }
    }

    private func resourceSummary(_ session: CockpitTab) -> String {
        gb(session.ramBytes) + " · " + String(Int(session.cpuPercent.rounded())) + "% CPU"
    }

    private func resourceTextColor(_ session: CockpitTab) -> Color {
        session.resourceState == .healthy ? Color.secondary.opacity(0.7) : resourceColor(session)
    }

    private var hibernatedChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "moon.zzz.fill").font(.system(size: 8.5, weight: .semibold))
            Text("hibernated").font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }

    private func modelChip(_ m: String) -> some View {
        Text(m).font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(track, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.secondary)
    }

    private func gLabel(_ t: String) -> some View {
        Text(LocalizedStringKey(t)).font(.system(size: 8.5, weight: .semibold)).tracking(0.8).foregroundStyle(.tertiary)
    }

    private func bar(fraction: Double, tone: Color, estimate: Bool, ticks: Bool) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(estimate ? Color.secondary.opacity(0.6) : tone)
                    .frame(width: max(2, geo.size.width * min(1, fraction)))
                if ticks {
                    ForEach([0.80, 0.95], id: \.self) { t in
                        // L04: blend bg+fg so the 80/95% marks stay visible over
                        // both the empty track AND a saturated orange/red fill.
                        Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.55)).frame(width: 1.5)
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
    /// Per-session RAM bar scale — 4 GB fills the bar (sessions rarely exceed that).
    private func ramFraction(_ bytes: UInt64) -> Double { min(1, Double(bytes) / 4_000_000_000) }
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

/// Review gate between native providers. Throttle copies only a bounded local
/// user/assistant excerpt, never tool output or hidden reasoning; the user reviews
/// the exact continuation packet before it reaches the fresh target session.
private struct MissionHandoffSheet: View {
    let handoff: MissionHandoff
    let onContinue: (MissionHandoff) -> Void
    let onCancel: () -> Void
    @State private var objective: String
    @State private var completed: String
    @State private var remaining: String
    @State private var validation: String
    @State private var blockers: String
    // Prospective router advisory (rules + the user's own shadow-replay ledger):
    // this sheet IS the task boundary — the one cache-safe moment to pick a lane.
    @State private var routerAdvice: RouterAdvisorService.Advice?
    @State private var replayLedger = ShadowReplayService.Ledger.empty

    init(
        handoff: MissionHandoff,
        onContinue: @escaping (MissionHandoff) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.handoff = handoff
        self.onContinue = onContinue
        self.onCancel = onCancel
        _objective = State(initialValue: handoff.objective)
        _completed = State(initialValue: handoff.context.completed)
        _remaining = State(initialValue: handoff.context.remaining)
        _validation = State(initialValue: handoff.context.validation)
        _blockers = State(initialValue: handoff.context.blockers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                runtime(handoff.source)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                runtime(handoff.target)
                Spacer()
                Text("MISSION \(handoff.missionID.uuidString.prefix(8))")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Continue this mission").font(.title2.weight(.semibold))
                Text("Throttle will hibernate the source first, then start a fresh \(handoff.target.label) session with the reviewed packet. Only one agent writes in this checkout.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("NEXT OBJECTIVE").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                TextEditor(text: $objective)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 82)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.10)) }
                if let advice = routerAdvice {
                    HStack(spacing: 8) {
                        Text(advice.recommendation.label.uppercased())
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.25)))
                        Text(([advice.reasons.first, advice.history].compactMap { $0 }).joined(separator: " · "))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .onAppear {
                replayLedger = ShadowReplayService.loadLedger()
                routerAdvice = RouterAdvisorService.advise(objective: objective, ledger: replayLedger)
            }
            .onChange(of: objective) {
                routerAdvice = RouterAdvisorService.advise(objective: objective, ledger: replayLedger)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("CONTINUATION LEDGER").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                ledgerField("Completed", text: $completed, prompt: "What is actually done?")
                ledgerField("Remaining", text: $remaining, prompt: "What should the target do next?")
                ledgerField("Validation", text: $validation, prompt: "Tests/builds run and their result")
                ledgerField("Blockers / risks", text: $blockers, prompt: "Unknowns, external gates, or risks")
            }

            if !handoff.context.recentConversation.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("PORTABLE CONTEXT")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(handoff.context.recentConversation)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 110)
                    .padding(9)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.10)) }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("SKILLS + MCP COMPATIBILITY")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(capabilityText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("FRESH GIT SNAPSHOT").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                Text(snapshotText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }

            Text("No Claude or Codex configuration is modified. The reviewed packet includes a bounded excerpt of user/assistant text, without tool output or hidden reasoning; the target revalidates the repository.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Continue with \(handoff.target.label)") {
                    onContinue(MissionHandoff(
                        sourceTabID: handoff.sourceTabID,
                        missionID: handoff.missionID,
                        projectName: handoff.projectName,
                        cwd: handoff.cwd,
                        source: handoff.source,
                        target: handoff.target,
                        sourceSessionID: handoff.sourceSessionID,
                        objective: objective,
                        context: MissionHandoffContext(
                            completed: completed,
                            remaining: remaining,
                            validation: validation,
                            blockers: blockers,
                            recentConversation: handoff.context.recentConversation
                        ),
                        capabilities: handoff.capabilities,
                        git: handoff.git
                    ))
                }
                .buttonStyle(.borderedProminent)
                .disabled(objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 620)
    }

    private var capabilityText: String {
        let c = handoff.capabilities
        func line(_ title: String, _ values: [String]) -> String {
            "\(title): \(values.isEmpty ? "none detected" : values.joined(separator: ", "))"
        }
        return [
            line("Shared skills", c.sharedSkills),
            line("Missing target skills", c.missingSkillsOnTarget),
            line("Shared MCP", c.sharedMCPServers),
            line("Missing target MCP", c.missingMCPServersOnTarget)
        ].joined(separator: "\n")
    }

    private func ledgerField(_ label: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 11, weight: .medium)).frame(width: 92, alignment: .leading)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))
        }
    }

    private func runtime(_ value: AgentRuntime) -> some View {
        Label(value.label, systemImage: value.symbol)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }

    private var snapshotText: String {
        let header = "branch \(handoff.git.branch ?? "unknown") · HEAD \(handoff.git.head ?? "unknown")"
        let status = handoff.git.statusLines.prefix(12).joined(separator: "\n")
        return status.isEmpty ? header + "\nworking tree clean or unavailable — target must recheck" : header + "\n" + status
    }
}

// MARK: - Toolbar primitives (Dir C · Claude Design 683dc5a2 · Toolbar.html)

/// Reads the toolbar's live width so the primary row can collapse to icon-only
/// below 860pt (mirrors the mock's container query without hard-coding a layout).
private struct BarWidthKey: PreferenceKey {
    static var defaultValue: CGFloat { 980 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// One segment of the view switcher — the dominant control. Active item is raised
/// onto an elevated surface with the accent; inactive is quiet, brightening on hover.
private struct SwitcherItem: View {
    let icon: String
    let label: String
    let isOn: Bool
    let iconOnly: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                if !iconOnly {
                    Text(label).font(.system(size: 11.5, weight: isOn ? .semibold : .medium))
                }
            }
            .foregroundStyle(isOn ? Color.accentColor : (hover ? Color.primary : Color.secondary))
            .padding(.horizontal, iconOnly ? 9 : 11).frame(height: 26)
            .background(isOn ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                             : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if isOn {
                    RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help(label)
    }
}

/// A stateful toolbar toggle (Audit, Shell): a bordered chip whose ON state fills
/// with a tinted accent + accent ring so it reads unmistakably as on, not momentary.
private struct ToolbarToggle: View {
    let icon: String
    var label: String
    let isOn: Bool
    let iconOnly: Bool
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12.5, weight: .medium))
                if !iconOnly { Text(label).font(.system(size: 11, weight: .medium)) }
            }
            .foregroundStyle(isOn ? Color.accentColor : (hover ? Color.primary : Color.secondary))
            .padding(.horizontal, iconOnly ? 7 : 9).frame(height: 26)
            .background(isOn ? Color.accentColor.opacity(0.14)
                             : (hover ? Color.primary.opacity(0.06) : Color.clear),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isOn ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.10), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .help(help).accessibilityValue(isOn ? String(localized: "On") : String(localized: "Off"))
    }
}

/// A quiet momentary utility glyph (26×26) for the revealed shelf. Optional `tint`
/// lets a stateful one (caffeine) show an accent without changing the footprint.
private struct ToolbarUtil: View {
    let icon: String
    let help: String
    var tint: Color? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint ?? (hover ? Color.primary : Color.secondary.opacity(0.85)))
                .frame(width: 26, height: 26)
                .background(hover ? Color.primary.opacity(0.06) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help(help)
    }
}

/// The reveal affordance: rotates 180° and turns accent when the utility shelf is open.
private struct RevealChevron: View {
    let isOpen: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isOpen ? Color.accentColor : (hover ? Color.primary : Color.secondary))
                .rotationEffect(.degrees(isOpen ? 180 : 0))
                .frame(width: 26, height: 26)
                .background(hover ? Color.primary.opacity(0.06) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .help(isOpen ? String(localized: "Hide utilities")
                     : String(localized: "More controls — timeline, theme, activity, setup, health"))
        .accessibilityLabel(String(localized: "More controls"))
    }
}
