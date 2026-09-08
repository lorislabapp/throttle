import AppKit
import SwiftUI
import ThrottleShared

extension MultiCockpitRoot {
    // MARK: C — Mission control

    var missionLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("All sessions").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(model.sessions.count) running · \(model.machine.agentSummary)")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }.padding(.horizontal, 18).padding(.top, 13).padding(.bottom, 4)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(model.sessions) { s in missionCard(s) }
                    addCard
                }.padding(.horizontal, 18).padding(.vertical, 12)
            }
        }
    }

    func missionCard(_ s: CockpitTab) -> some View {
        let active = s.id == model.active?.id
        return Button { model.wake(s.id); model.viewMode = .rail } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    stateDot(s)
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

    var addCard: some View {
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

    var emptyState: some View {
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
    func newSessionMenu<L: View>(gated: Bool, @ViewBuilder label: () -> L) -> some View {
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

    func open(_ name: String, _ cwd: String) {
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

    enum DuplicateProjectChoice {
        case focusExisting, openAnother, cancel
    }

    func confirmDuplicateProject(name: String, count: Int) -> DuplicateProjectChoice {
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

    func chooseRuntimeForNewSession() -> AgentRuntime? {
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
    func confirmOpenUnderPressure() -> Bool {
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

    func openFolderPanel() {
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
    func stateDot(_ s: CockpitTab) -> some View { SessionStateDot(tab: s) }
}
