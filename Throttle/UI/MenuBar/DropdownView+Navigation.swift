import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

extension DropdownView {
    var dockFooter: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                DockTile(icon: "chart.line.uptrend.xyaxis", label: "Stats") {
                    mode = .stats
                }
                DockTile(icon: "rectangle.split.3x1", label: "Project",
                         badgeText: appState.isPro ? nil : "PRO", badgeStyle: .pro) {
                    ProjectWindowController.shared.show(appState: appState)
                }
                DockTile(icon: "terminal", label: "Cockpit",
                         badgeText: appState.isPro ? "BETA" : "PRO",
                         badgeStyle: appState.isPro ? .beta : .pro) {
                    if appState.isPro {
                        CockpitWindowController.shared.show(appState: appState)
                    } else {
                        mode = .settings(.pro)   // Pro feature → upsell
                    }
                }
                DockTile(icon: "chevron.left.forwardslash.chevron.right", label: "Commands",
                         badgeText: appState.isPro ? nil : "PRO", badgeStyle: .pro) {
                    if appState.isPro { CommandRunnerWindowController.shared.show() } else { mode = .settings(.pro) }
                }
                DockTile(icon: "magnifyingglass", label: "Search") {
                    ResearchVaultWindowController.shared.show(query: "")
                }
                DockTile(icon: "gear", label: "Settings") {
                    mode = .settings(.general)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)

            dockMeta
        }
        .padding(.bottom, 8)
    }

    /// The quiet meta line under the dock: sign-in status on the left, demoted
    /// chrome (Usage / About / Quit) on the right, separated from the dock by a
    /// hairline. Sign-in is always tappable (opens the embedded sign-in / re-auth
    /// window) so the user never has to wait for an exact-mode poll to fail first.
    var dockMeta: some View {
        VStack(spacing: 0) {
            Rectangle().fill(hairColor).frame(height: 1)
            HStack(spacing: 8) {
                Button {
                    Task { @MainActor in
                        let signed = await EmbeddedClaudeSession.shared.presentSignIn()
                        if signed { await ExactModeService.shared.refresh() }
                    }
                } label: {
                    if embeddedSignedIn {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text("claude.ai").foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                            Text("Sign in…").foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                HStack(spacing: 11) {
                    metaLink("Usage", systemImage: "arrow.up.right") {
                        if let url = URL(string: "https://claude.ai/settings/usage") {
                            NSWorkspace.openInBackground(url)
                        }
                    }
                    metaLink("Vault") {
                        ResearchVaultWindowController.shared.show(query: "")
                    }
                    metaLink("About") { mode = .settings(.about) }
                    metaLink("Quit") { NSApp.terminate(nil) }
                        .keyboardShortcut("q")
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 9)
            .padding(.top, 8)
        }
        .padding(.horizontal, 5)
        .padding(.top, 7)
    }

    /// A small tertiary text link for the demoted-chrome group in the meta line.
    func metaLink(_ title: LocalizedStringKey, systemImage: String? = nil,
                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 9.5))
                }
                Text(title)
            }
            .foregroundStyle(.tertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Settings mode

    func settingsContent(tab: SettingsTab) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Button { mode = .meter } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                Text("Throttle").font(.system(size: 14.5, weight: .semibold))
                Text("Settings").font(.system(size: 12)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if appState.isPro { pillSoft("PRO") } else { pillFree("FREE") }
                if appState.exactSnapshot?.isFresh() == true {
                    HStack(spacing: 4) {
                        Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 4, height: 4)
                        Text("EXACT")
                    }
                    .font(.system(size: 9.5, weight: .heavy))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                }
            }
            .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 9)

            settingsTabBar(current: tab)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .general:     InlineGeneralPane()
                    case .pro:         InlineProPane()
                    case .assistant:   InlineAssistantPane()
                    case .calibration: InlineCalibrationPane()
                    case .hooks:       InlineHooksPane()
                    case .about:       InlineAboutPane()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 220, maxHeight: 380)
        }
    }

    /// Direction A console tab bar — six terse tabs; active gets accent text +
    /// a 2pt accent underline. One pane scrolls beneath.
    @ViewBuilder
    func settingsTabBar(current: SettingsTab) -> some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases, id: \.self) { t in
                let on = t == current
                Button { mode = .settings(t) } label: {
                    Text(t.tabLabel)
                        .font(.system(size: 11.5, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .overlay(alignment: .bottom) {
                            if on {
                                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor)
                                    .frame(height: 2).padding(.horizontal, 6)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1)
        }
    }
}
