import AppKit
import SwiftUI
import ThrottleShared

extension MultiCockpitRoot {
    // MARK: - Content (the active layout)

    @ViewBuilder
    var content: some View {
        if model.viewMode == .dashboard {
            // The cover page — stats work even with no live session.
            CockpitDashboardView(machine: model.machine).environment(appState)
        } else if model.viewMode == .portfolio || model.viewMode == .plan {
            CockpitSpecialView(cockpit: model)
        } else if model.sessions.isEmpty {
            emptyState
        } else {
            switch model.viewMode {
            case .tabs:    tabsLayout
            case .rail:    railLayout
            case .mission: missionLayout
            case .dashboard, .portfolio, .plan: EmptyView()   // handled above
            }
        }
    }

    var terminal: some View {
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
        .onAppear {
            guard remoteSvc.isConfigured else { return }
            // Tell the user when a session on the box ends, instead of removing a
            // row and hoping they notice. The box has its own memory limits, and
            // an OOM there looks exactly like nothing happening here.
            remoteSvc.onSessionVanished = { session in
                CockpitNotifier.shared.notifyRemoteSessionEnded(
                    project: session.project)
            }
            remoteSvc.onTranscriptTooLarge = { session, why in
                CockpitNotifier.shared.notifyWaiting(project: session.project,
                                                     question: why, tabID: UUID())
            }
            remoteSvc.startPolling()
        }
        // Sits ABOVE the pane on purpose. The whole failure is that the pane looks
        // unchanged when the agent has gone and the shell underneath is taking
        // keystrokes; a marker in the rail would be exactly the sign the user
        // already missed.
        .overlay(alignment: .top) {
            if let active = model.active, active.inputSuspended {
                agentExitedBanner(active)
            } else if let active = model.active, let reason = active.pauseReason {
                frozenBanner(active, reason)
            }
        }
    }

    /// Same rule as the agent-exited banner, for the same reason: a SIGSTOPped
    /// session renders its last frame forever. The spinner sits mid-animation, scroll
    /// does nothing (a full-screen TUI takes wheel reports, and a stopped process
    /// reads none), and typing goes nowhere — which reads as "the terminal is broken",
    /// not as "Throttle froze this on purpose". The rail glyph is not enough: it is one
    /// small icon in a list of fifty. Say it over the pane, say WHY, and offer the
    /// single control that undoes it.
    func frozenBanner(_ tab: CockpitTab, _ reason: CockpitTab.PauseReason) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill").foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 1) {
                Text(reason.title)
                    .font(.system(size: 12, weight: .medium))
                Text(reason.detail)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Resume") { tab.resumeProcess() }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
        }
    }

    func agentExitedBanner(_ tab: CockpitTab) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(tab.runtime.shortLabel) exited twice — typing is suspended")
                    .font(.system(size: 12, weight: .medium))
                Text("The login shell underneath is still live. Keystrokes are dropped so nothing runs there by accident.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Resume") { tab.relaunchAgent() }
                .buttonStyle(.borderedProminent).controlSize(.small)
            Button("Use shell") { tab.acceptShell() }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
        }
    }

    // MARK: A — Tab bar

    var tabsLayout: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(model.visibleSessions) { tab in
                        let selected = tab.id == (model.active?.id)
                        Button { model.wake(tab.id) } label: {
                            HStack(spacing: 8) {
                                stateDot(tab)
                                Text(tab.projectName).font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(selected ? .primary : .secondary)
                                runtimeTag(tab.runtime)
                                if tab.needsInput {
                                    Image(systemName: "bell.badge.fill").font(.system(size: 10))
                                        .foregroundStyle(.orange)
                                }
                                if let eur = tab.eur {
                                    Text(String(format: "€%.2f", eur))
                                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                }
                                Button { Task { await model.close(tab.id) } } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.tertiary)
                                }.buttonStyle(.plain)
                            }
                            .padding(.horizontal, 12).frame(minHeight: 40)
                            .background(selected ? Color.primary.opacity(0.06) : .clear)
                            .overlay(alignment: .bottom) {
                                if selected {
                                    Rectangle().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 10)
                                }
                            }
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if model.visibleSessions.isEmpty, model.activityFilter != .all, !model.sessions.isEmpty {
                        activityFilterEmptyTab
                    }
                    activityFilterMenu.padding(.horizontal, 6).frame(minHeight: 40)
                    newTabButton
                }
                .padding(.horizontal, 6)
            }
            .overlay(alignment: .bottom) { Rectangle().fill(hair).frame(height: 1) }
            terminal
        }
    }

    var newTabButton: some View {
        newSessionMenu(gated: model.gated) {
            Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 12).frame(minHeight: 40).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(model.gated ? "Mac saturated" : "New session")
    }

    func runtimeTag(_ runtime: AgentRuntime) -> some View {
        Text(runtime.shortLabel.uppercased())
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .foregroundStyle(runtime == .claudeCode ? Color.orange : Color.accentColor)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel(runtime.label)
    }
}
