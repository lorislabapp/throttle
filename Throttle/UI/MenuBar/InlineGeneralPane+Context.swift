import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

extension InlineGeneralPane {
    @ViewBuilder
    var contextSettings: some View {
        SettingsHair()
        SettingsRow(title: "Concise Claude Code replies",
                    sub: conciseError
                ?? """
                Injects a one-line be-brief directive beside every prompt and after \
                compaction (hooks) — reaches sessions already open, where an output style \
                can't. Honest ceiling: output tokens are typically 7–16% of total spend.
                """
        ) {
            Toggle("", isOn: $conciseClaudeCode).labelsHidden().toggleStyle(.switch).tint(.accentColor)
                .onChange(of: conciseClaudeCode) { _, on in setConciseFlag(on) }
        }
        SettingsHair()
        SettingsRow(title: "Claude Code output style",
            sub:
                """
                Active: \(activeStyle). Changes take effect next session or after /clear. \
                Pick a built-in, or create your own (Caveman, Concise…).
                """
        ) {
            HStack(spacing: 6) {
                if !appState.isPro {
                    Text("PRO").font(.system(size: 9, weight: .heavy)).tracking(0.3)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                }
                SettingsButton(title: "Manage…") {
                    if appState.isPro { OutputStyleWindowController.shared.show() }
                }
                .disabled(!appState.isPro)
            }
        }
        SettingsHair()
        SettingsRow(title: "MCP servers",
            sub:
                """
                List every MCP server across scopes, move Global ↔ Project-local ↔ \
                shareable .mcp.json, enable/disable, add or remove. Throttle backs up each \
                file first.
                """
        ) {
            HStack(spacing: 6) {
                if !appState.isPro {
                    Text("PRO").font(.system(size: 9, weight: .heavy)).tracking(0.3)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                }
                SettingsButton(title: "Manage…") {
                    if appState.isPro { MCPManagerWindowController.shared.show() }
                }
                .disabled(!appState.isPro)
            }
        }
        SettingsHair()
        SettingsRow(title: "Command runner",
            sub:
                """
                Run saved shell commands from Throttle — no claude session, no `!`, zero \
                tokens. Output stays local. Runs via your login shell (PATH + secrets).
                """
        ) {
            HStack(spacing: 6) {
                if !appState.isPro {
                    Text("PRO").font(.system(size: 9, weight: .heavy)).tracking(0.3)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                }
                SettingsButton(title: "Open…") {
                    if appState.isPro { CommandRunnerWindowController.shared.show() }
                }
                .disabled(!appState.isPro)
            }
        }
        SettingsHair()
        SettingsRow(title: "Compress command output",
                    sub: tokoptNote.isEmpty
                ? """
                Installs a PostToolUse hook that strips ANSI, dedups and trims verbose CLI \
                output before Claude sees it — fewer tokens, errors always passed through \
                raw. Reversible; restart Claude Code after.
                """
                        : tokoptNote) {
            HStack(spacing: 6) {
                if !appState.isPro {
                    Text("PRO").font(.system(size: 9, weight: .heavy)).tracking(0.3)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                }
                Toggle("", isOn: appState.isPro ? $tokoptOn : .constant(false))
                    .labelsHidden().toggleStyle(.switch).tint(.accentColor)
                    .disabled(!appState.isPro)
                    .onChange(of: tokoptOn) { _, on in
                        guard appState.isPro else { return }
                        Task.detached(priority: .utility) {
                            if on { _ = try? TokoptHookInstaller.install() } else { try? TokoptHookInstaller.remove() }
                        }
                        tokoptNote = on
                            ? "Installed — restart Claude Code to start compressing."
                            : "Removed — restart Claude Code."
                    }
            }
        }
        SettingsHair()
        SettingsRow(title: "Throttle as an MCP source",
                    sub: memoryNote.isEmpty
                ? """
                Installs the same local Context Firewall and global portfolio RAG in \
                Claude Code and Codex: projects, reusable capabilities, tools, workflows, \
                handoffs, focused reads and session recall. Local, backed up and \
                reversible; restart both agents after.
                """
                        : memoryNote) {
            HStack(spacing: 6) {
                if !appState.isPro {
                    Text("PRO").font(.system(size: 9, weight: .heavy)).tracking(0.3)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                }
                Toggle("", isOn: appState.isPro ? $memoryOn : .constant(false))
                    .labelsHidden().toggleStyle(.switch).tint(.accentColor)
                    .disabled(!appState.isPro)
                    .onChange(of: memoryOn) { _, on in
                        guard appState.isPro else { return }
                        Task {
                            let failure: String? = await Task.detached(priority: .utility) {
                                do {
                                    if on {
                                        _ = try TranscriptMemoryInstaller.install()
                                    } else {
                                        try TranscriptMemoryInstaller.remove()
                                    }
                                    return nil
                                } catch {
                                    return error.localizedDescription
                                }
                            }.value
                            if let failure {
                                memoryNote = "Could not update Claude Code + Codex: \(failure)"
                            } else {
                                memoryNote = on
                                    ? "Installed for Claude Code + Codex — restart both agents to load the shared tools."
                                    : "Removed from Claude Code + Codex — restart both agents."
                                if on && !UserDefaults.standard.bool(forKey: GlobalRAGOnboardingService.completedKey) {
                                    showGlobalRAGOnboarding()
                                }
                            }
                        }
                    }
            }
        }
        SettingsHair()
        SettingsRow(title: "Global portfolio RAG profile",
                    sub: globalRAGNote.isEmpty
                ? """
                Optional, portable post-install configuration. Import or export versioned \
                JSON/YAML roots, aliases, capabilities, tools, workflows and handoffs. No \
                project or personal data is built into Throttle; secret-looking fields are \
                refused.
                """
                        : globalRAGNote) {
            HStack(spacing: 6) {
                SettingsButton(title: "Setup…") { showGlobalRAGOnboarding() }
                SettingsButton(title: "Import…") { importGlobalRAGProfile() }
                SettingsButton(title: "JSON") { exportGlobalRAGProfile(.json) }
                SettingsButton(title: "YAML") { exportGlobalRAGProfile(.yaml) }
            }
        }
        SettingsHair()
        SettingsRow(title: "Attribute cost per skill (Traycer)",
                    sub: traycerNote.isEmpty
                ? """
                Turns on Claude Code's local OpenTelemetry export to a receiver inside \
                Throttle, so the Project window can show € per skill. Full shell command \
                lines are logged to the local usage.db (never leaves your Mac; prompt text \
                is never captured). Reversible; restart Claude Code after.
                """
                        : traycerNote) {
            HStack(spacing: 6) {
                if !appState.isPro {
                    Text("PRO").font(.system(size: 9, weight: .heavy)).tracking(0.3)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                }
                Toggle("", isOn: appState.isPro ? $traycerOn : .constant(false))
                    .labelsHidden().toggleStyle(.switch).tint(.accentColor)
                    .disabled(!appState.isPro)
                    .onChange(of: traycerOn) { _, on in
                        guard appState.isPro else { return }
                        UserDefaults.standard.set(on, forKey: "throttleTraycerEnabled")
                        let writer = appState.database
                        if on {
                            Task.detached(priority: .utility) { _ = try? TraycerEnvInstaller.install() }
                            TraycerReceiver.shared.start(writer: writer)   // live now for new sessions
                        } else {
                            Task.detached(priority: .utility) { try? TraycerEnvInstaller.remove() }
                            TraycerReceiver.shared.stop()
                        }
                        traycerNote = on
                            ? """
                            Installed — restart Claude Code to start exporting; € per skill appears in \
                            the Project window.
                            """
                            : "Removed — restart Claude Code."
                    }
            }
        }
        SettingsHair()
        SettingsRow(title: "Web research (local render)",
                    sub: webNote.isEmpty
                        ? """
                        Adds provider-neutral web_render + research_grounded tools to Claude Code and Codex. \
                        WebKit renders JavaScript privately, then the Context Firewall returns exact \
                        query-focused excerpts with line numbers and a rehydratable original. Cookie-less, \
                        public URLs only; redirects and private DNS targets are blocked.
                        """
                        : webNote) {
            HStack(spacing: 6) {
                if !appState.isPro {
                    Text("PRO").font(.system(size: 9, weight: .heavy)).tracking(0.3)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                }
                Toggle("", isOn: appState.isPro ? $webOn : .constant(false))
                    .labelsHidden().toggleStyle(.switch).tint(.accentColor)
                    .disabled(!appState.isPro)
                    .onChange(of: webOn) { _, on in
                        guard appState.isPro else { return }
                        UserDefaults.standard.set(on, forKey: "throttleWebEnabled")
                        if on {
                            // Live now; web_render appears in new sessions.
                            WebRenderBridge.shared.start(writer: appState.database)
                            webNote = "On — restart Claude Code and Codex so both pick up the web research tools."
                        } else {
                            // Keep the loopback bridge alive for embedded-model
                            // Context Firewall summaries; /render itself now
                            // rejects requests while this preference is off.
                            webNote = "Off — restart Claude Code and Codex to drop the web research tools."
                        }
                    }
            }
        }
    }
}
