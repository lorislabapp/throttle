import AppKit
import SwiftUI
import ThrottleShared

extension MultiCockpitRoot {
    // MARK: - Top bar (switcher + pills)

    /// Dir C — "The Reveal Row" (Claude Design 683dc5a2 · Toolbar.html). Two rows:
    /// a calm 40pt primary row (identity · view switcher · stateful toggles · status)
    /// and a 36pt utility shelf (timeline + occasional utilities) that the chevron
    /// reveals. See docs/UI-SPEC-cockpit-toolbar.md.
    var topBar: some View {
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

    func primaryRow(narrow: Bool) -> some View {
        HStack(spacing: 6) {
            identity(compact: narrow)
            zsep
            routingMenu(compact: narrow)
            zsep
            viewSwitcher(iconsOnly: narrow)
            Spacer(minLength: 6)
            knowledgeMenu(compact: narrow)
            ToolbarToggle(icon: "sidebar.trailing", label: String(localized: "Panel"), isOn: showSidebar,
                          iconOnly: narrow,
                          help: String(localized: "Audit metrics and the prompt refiner")) {
                showSidebar.toggle()
            }
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

    func routingMenu(compact: Bool) -> some View {
        Button {
            AIRoutingWindowController.shared.show()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                if !compact { Text(model.routingMode.label) }
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Open AI Routing — coding sessions, local/frontier inference and fallback rules")
        .accessibilityLabel(String(localized: "Mission runtime"))
        .accessibilityValue(model.routingMode.label)
    }

    func knowledgeMenu(compact: Bool) -> some View {
        Menu {
            Button("Research Vault", systemImage: "books.vertical") {
                ResearchVaultWindowController.shared.show(query: "")
            }
            Button("Global Portfolio Setup", systemImage: "square.stack.3d.up") {
                GlobalRAGOnboardingWindowController.shared.show(canInstallMCP: appState.isPro) { _ in }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "books.vertical")
                if !compact { Text("Research") }
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
        .help("Research Vault and Global Portfolio Setup")
        .accessibilityLabel("Research and global portfolio")
    }

    /// The revealed utility shelf: contextual timeline (or an empty note) on the
    /// left, the occasional utilities on the right. Height collapses to 0 when hidden.
    func utilityRow(narrow: Bool) -> some View {
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

    func identity(compact: Bool) -> some View {
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

    func statusCluster(narrow: Bool) -> some View {
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
    var styleIndicator: some View {
        Button { OutputStyleWindowController.shared.show() } label: {
            Text(styleShort(activeStyle))
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(String.localizedStringWithFormat(
            String(localized: "Output style: %@ — click to change"), activeStyle))
    }

    func styleShort(_ s: String) -> String {
        s == "Default" ? "Default" : s.replacingOccurrences(of: "Throttle ", with: "")
    }

    /// Jump the active terminal between conversation turns (prev/next prompt or
    /// response) and back to live — a timeline for the session.
    var timelineNav: some View {
        HStack(spacing: 2) {
            navButton("chevron.up", String(localized: "Previous turn")) { model.jumpTurn(older: true) }
            navButton("chevron.down", String(localized: "Next turn")) { model.jumpTurn(older: false) }
            navButton("arrow.down.to.line", String(localized: "Jump to live")) { model.scrollLive() }
        }
        .padding(.horizontal, 4)
        .overlay(alignment: .leading) { Rectangle().fill(hair).frame(width: 1).padding(.vertical, 6) }
        .overlay(alignment: .trailing) { Rectangle().fill(hair).frame(width: 1).padding(.vertical, 6) }
    }

    func navButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary).frame(width: 22, height: 22).contentShape(Rectangle())
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    /// Caffeine: keep the Mac from idle-sleeping while sessions run (lid open).
    var caffeineToggle: some View {
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
    var themeMenu: some View {
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
    func viewSwitcher(iconsOnly: Bool) -> some View {
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

    func viewIcon(_ m: MultiCockpitModel.ViewMode) -> String {
        switch m {
        case .dashboard: return "square.grid.2x2"
        case .tabs:      return "macwindow"
        case .rail:      return "sidebar.left"
        case .mission:   return "rectangle.3.group"
        case .portfolio, .plan: return CockpitSpecialView.icon(for: model.viewMode)
        }
    }
}
