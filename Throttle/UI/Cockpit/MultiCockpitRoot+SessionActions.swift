import AppKit
import SwiftUI
import ThrottleShared

extension MultiCockpitRoot {
    /// The per-session action menu — the "decision layer" surfaced as one right-click:
    /// switch model (cheap task → Haiku), offload to the server, freeze/close. Shared
    /// by the row's right-click context menu AND the ⋯ hover button so the actions are
    /// discoverable, not hidden behind a right-click only power users try.
    @ViewBuilder func sessionMenu(_ s: CockpitTab) -> some View {
        let target: AgentRuntime = s.runtime == .claudeCode ? .codex : .claudeCode
        Button {
            requestHandoff(s, to: target)
        } label: {
            Label("Continue mission with \(target.label)", systemImage: "arrow.left.arrow.right")
        }
        Divider()
        if s.isSpawned {
            Menu("Switch Claude model") {
                Button("Fable") { requestModelSwitch(s, to: "fable") }
                Button("Opus") { requestModelSwitch(s, to: "opus") }
                Button("Sonnet") { requestModelSwitch(s, to: "sonnet") }
                Button("Haiku") { requestModelSwitch(s, to: "haiku") }
            }
            .disabled(s.runtime != .claudeCode)
        }
        // One-click offload of THIS session. The menu always says what will
        // actually happen: not configured → open setup; already on the box → show
        // it / bring it back / stop it; otherwise → upload + resume, no sheet.
        if !remoteSvc.isConfigured {
            Button("Offload to server — set up…") { SessionOffloadWindowController.shared.show() }
        } else if let rid = s.offloadedRemoteID {
            Button("Show remote session") { selectedRemoteID = rid }
            Button("Reconcile transfer") { Task { await remoteSvc.reconcileTransfer(s, requestStop: false) } }
            Button("Bring back to Mac") { bringBack(s) }
            Button("Stop remote session") {
                Task {
                    await remoteSvc.reconcileTransfer(s, requestStop: true)
                    model.persist()
                }
            }
        } else {
            Button("Offload to server (with context)") { offloadTab(s) }
        }
        Button("Server settings…") { SessionOffloadWindowController.shared.show() }
        Divider()
        if s.isSpawned {
            Button(s.isPaused ? "Resume" : "Pause") { s.isPaused ? s.resumeProcess() : s.pauseProcess(reason: .user) }
            Button(hibernateActionLabel(s)) { Task { await model.hibernate(s.id) } }
        }
        Button("Project stats + optimizer") {
            ProjectWindowController.shared.show(
                appState: appState, projectID: MultiCockpitModel.claudeProjectDirName(s.cwd))
        }
        Divider()
        Button("Close session", role: .destructive) { Task { await model.close(s.id) } }
    }

    func requestHandoff(_ session: CockpitTab, to target: AgentRuntime) {
        let sourceTabID = session.id
        let missionID = session.missionID
        let projectName = session.projectName
        let cwd = session.cwd
        let source = session.runtime
        let sourceSessionID = session.sessionId
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
                objective: PromptRefinerModel.shared.pendingMissionObjective
                    ?? "Continue the current work at the next unfinished task.",
                context: MissionHandoffContext(
                    completed: "", remaining: "", validation: "", blockers: "",
                    recentConversation: snapshot.1
                ),
                capabilities: snapshot.2,
                git: snapshot.0
            )
        }
    }

    func requestModelSwitch(_ session: CockpitTab, to target: String) {
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

    func performModelSwitch(_ request: PendingModelSwitch) {
        if let session = model.sessions.first(where: { $0.id == request.tabID }) {
            session.confirmedModelSwitchTarget = request.target
            session.terminal?.send(txt: "/model \(request.target)\n")
        }
        pendingModelSwitch = nil
    }

    func hibernateActionLabel(_ session: CockpitTab) -> String {
        guard let impact = session.promptCacheImpact, impact.shouldWarn else {
            return "Hibernate — free RAM, keep context"
        }
        return
            """
            Hibernate — resume may reload ≈\(fmtTok(impact.contextTokens)) input \
            (≈€\(String(format: "%.2f", impact.rebuildEUR)))
            """
    }

    func resumeImpactText(_ session: CockpitTab) -> String? {
        guard let impact = session.promptCacheImpact, impact.shouldWarn else { return nil }
        return "≈\(fmtTok(impact.contextTokens)) input · ≈€\(String(format: "%.2f", impact.rebuildEUR))"
    }

    /// One icon button in the rail-row hover cluster.
    func railAction(
        _ icon: String, _ size: CGFloat, _ color: Color, _ help: String, _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size)).foregroundStyle(color)
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}
