import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

extension InlineGeneralPane {
    func showGlobalRAGOnboarding() {
        GlobalRAGOnboardingWindowController.shared.show(canInstallMCP: appState.isPro) { note in
            globalRAGNote = note
            memoryOn = TranscriptMemoryInstaller.isInstalled()
        }
    }

    // MARK: - Autopilot

    @ViewBuilder
    var autopilotGroup: some View {
        SettingsGroupHeader(label: "Autopilot")
        SettingsRow(title: "Optimize Claude Code system-wide",
                    sub: "Installs a concise output-style (every session stays terse, reasoning untouched) + a usage statusline (live headroom in every terminal tab). 100% local, reversible.") {
            HStack(spacing: 6) {
                if !appState.isPro {
                    Text("PRO").font(.system(size: 9, weight: .heavy)).tracking(0.3)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                }
                Toggle("", isOn: appState.isPro ? $autopilotOn : .constant(false))
                    .labelsHidden().toggleStyle(.switch).tint(.accentColor)
                    .disabled(!appState.isPro)
                    .onChange(of: autopilotOn) { _, on in
                        guard appState.isPro else { return }
                        AutopilotService.isEnabled = on
                        guard on else { return }
                        autopilotBusy = true
                        Task {
                            let made = await Task.detached(priority: .utility) { AutopilotService.runPass() }.value
                            ledger = AutopilotService.load()
                            autopilotBusy = false
                            _ = made
                        }
                    }
            }
        }
        SettingsHair()
        SettingsRow(title: "Auto-archive stale memory",
                    sub: "Off by default — the 30-day heuristic is blunt. Never touches MEMORY.md. Reversible.") {
            Toggle("", isOn: $apMemory).labelsHidden().toggleStyle(.switch).tint(.orange)
                .disabled(!autopilotOn)
                .onChange(of: apMemory) { _, on in AutopilotService.archiveStaleMemory = on }
        }
        SettingsHair()
        SettingsRow(title: "Auto-archive dead skills",
                    sub: "Off by default — never invoked ≠ unwanted. Skills named in your CLAUDE.md are kept. Reversible.") {
            Toggle("", isOn: $apSkills).labelsHidden().toggleStyle(.switch).tint(.orange)
                .disabled(!autopilotOn)
                .onChange(of: apSkills) { _, on in AutopilotService.archiveDeadSkills = on }
        }
        SettingsHair()
        SettingsRow(title: "Semantic project index",
                    sub: "Off by default. Builds a local on-device index of your projects so throttle_semantic_search finds code by meaning. CPU-heavy; auto-paused under memory pressure. 100% local; updates incrementally on launch.") {
            Toggle("", isOn: $semanticAutoIndex).labelsHidden().toggleStyle(.switch).tint(.accentColor)
                .onChange(of: semanticAutoIndex) { _, on in SemanticAutoIndexer.isEnabled = on }
        }
        SettingsHair()
        SettingsRow(title: "Activity log", sub: autopilotStatusSub) {
            if autopilotBusy {
                ProgressView().controlSize(.small)
            } else {
                SettingsButton(title: "Review & undo…") {
                    ledger = AutopilotService.load()
                    showingLedger = true
                }
            }
        }
        SettingsNote(text: "Manual one-tap optimizers (transcript trim, dedup hoist) live in the Cockpit — they touch live content, so they stay deliberate.")
    }

    var autopilotStatusSub: String {
        let entries = AutopilotService.load()
        let active = entries.filter { !$0.undone }.count
        if !AutopilotService.isEnabled { return "Off — turn on to keep your setup optimized." }
        if let last = AutopilotService.lastRun {
            return "\(active) active change\(active == 1 ? "" : "s") · last run \(formatRelative(last))"
        }
        return entries.isEmpty ? "On — first pass runs shortly." : "\(active) active change\(active == 1 ? "" : "s")"
    }

    var autopilotLedgerSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Autopilot activity").font(.system(size: 15, weight: .semibold))
                    Text("Everything Throttle changed on your behalf. Each is reversible — nothing left your Mac.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Done") { showingLedger = false }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            if ledger.isEmpty {
                Text("No changes yet.").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 36)
            } else {
                ScrollView { VStack(spacing: 0) { ForEach(ledger) { ledgerRow($0) } } }
            }
            Divider()
            HStack {
                Button("Undo all") {
                    AutopilotService.undoAll(); ledger = AutopilotService.load()
                }
                .disabled(ledger.allSatisfy { $0.undone })
                Spacer()
                Button("Disable & undo everything", role: .destructive) {
                    AutopilotService.disable(undoEverything: true)
                    autopilotOn = false; ledger = AutopilotService.load(); showingLedger = false
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 540, height: 440)
    }

    func ledgerRow(_ e: AutopilotService.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ledgerIcon(e.kind))
                .font(.system(size: 12)).foregroundStyle(e.undone ? .tertiary : .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.summary).font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(e.undone ? .tertiary : .primary)
                    .strikethrough(e.undone).lineLimit(2)
                if let why = e.detail, !e.undone {
                    Text(why).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(formatRelative(e.timestamp)).font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            if e.undone {
                Text("undone").font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                Button("Undo") { _ = AutopilotService.undo(e.id); ledger = AutopilotService.load() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1) }
    }

    func ledgerIcon(_ k: AutopilotService.Entry.Kind) -> String {
        switch k {
        case .outputStyle: return "text.alignleft"
        case .statusline:  return "menubar.rectangle"
        case .memory:      return "clock.badge.xmark"
        case .skills:      return "wrench.adjustable"
        case .brevityHook: return "scissors"
        }
    }

    var updatesSubtitle: String {
        if let last = UpdaterService.shared.lastCheckDate {
            return "Auto-checks daily · last checked \(formatRelative(last))"
        }
        return "Auto-checks daily · not checked yet"
    }

    func handleCalendarResult(_ result: CalendarReminderService.Result) {
        switch result {
        case .added:        calendarStatus = "✓ Event added to your default calendar."
        case .denied:       calendarStatus = "Calendar access denied — enable in System Settings."
        case .noResetTime:  calendarStatus = "No reset time available yet — keep using Claude Code."
        case .error(let m): calendarStatus = "Error: \(m)"
        }
    }

    func formatRelative(_ date: Date) -> String {
        let secs = -Int(date.timeIntervalSinceNow)
        if secs < 60 { return "\(secs)s ago" }
        let m = secs / 60
        if m < 60 { return "\(m)m ago" }
        return "\(m / 60)h \(m % 60)m ago"
    }

    var currentVersionLabel: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(v) (\(b))"
    }
}
