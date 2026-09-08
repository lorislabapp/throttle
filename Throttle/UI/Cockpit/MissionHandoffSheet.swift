import AppKit
import SwiftUI
import ThrottleShared

struct MissionHandoffSheet: View {
    let handoff: MissionHandoff
    let onContinue: (MissionHandoff) -> Void
    let onCancel: () -> Void
    @State var objective: String
    @State var completed: String
    @State var remaining: String
    @State var validation: String
    @State var blockers: String
    // Prospective router advisory (rules + the user's own shadow-replay ledger):
    // this sheet IS the task boundary — the one cache-safe moment to pick a lane.
    @State var routerAdvice: RouterAdvisorService.Advice?
    @State var replayLedger = ShadowReplayService.Ledger.empty

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

    var capabilityText: String {
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

    func ledgerField(_ label: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 11, weight: .medium)).frame(width: 92, alignment: .leading)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))
        }
    }

    func runtime(_ value: AgentRuntime) -> some View {
        Label(value.label, systemImage: value.symbol)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }

    var snapshotText: String {
        let header = "branch \(handoff.git.branch ?? "unknown") · HEAD \(handoff.git.head ?? "unknown")"
        let status = handoff.git.statusLines.prefix(12).joined(separator: "\n")
        return status.isEmpty ? header + "\nworking tree clean or unavailable — target must recheck" : header + "\n" + status
    }
}

// MARK: - Toolbar primitives (Dir C · Claude Design 683dc5a2 · Toolbar.html)

/// Reads the toolbar's live width so the primary row can collapse to icon-only
/// below 860pt (mirrors the mock's container query without hard-coding a layout).
