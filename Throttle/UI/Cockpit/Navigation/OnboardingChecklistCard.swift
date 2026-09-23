import SwiftUI

/// "First steps" at the top of Today: five steps in the order the product is
/// used, each ticked when it really happened, each with a button that takes
/// the person to the exact place to do it.
struct OnboardingChecklistCard: View {
    @Bindable var cockpit: MultiCockpitModel
    var projects: CockpitProjectsModel
    @State private var dismissed = CockpitOnboarding.isDismissed()
    /// Re-reads the stored flags when a step is recorded elsewhere.
    @State private var refreshToken = UUID()

    var body: some View {
        let done = completed
        if !dismissed, done.count < CockpitOnboarding.Step.allCases.count {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("First steps").font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Text(verbatim: "\(done.count)/\(CockpitOnboarding.Step.allCases.count)")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button("Hide") {
                        CockpitOnboarding.dismiss()
                        dismissed = true
                    }
                    .buttonStyle(.link).font(.system(size: 12))
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
                Divider()
                ForEach(CockpitOnboarding.Step.allCases) { step in
                    row(step, isDone: done.contains(step), isCurrent: CockpitOnboarding.current(in: done) == step)
                    Divider()
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.35)))
            .onAppear { OnboardingTips.currentStep = CockpitOnboarding.current(in: done)?.rawValue ?? "" }
            .onChange(of: cockpit.destination) { _, _ in refreshToken = UUID() }
        }
    }

    private var completed: Set<CockpitOnboarding.Step> {
        _ = refreshToken
        return CockpitOnboarding.completed(
            hasPlan: projects.summaries.contains { $0.overview != nil },
            hasSettledDecision: projects.summaries.contains { summary in
                summary.overview?.tasks.contains { task in
                    task.state.runtime == HumanDecisionRecorder.runtime
                        && [.verified, .integrated, .candidate].contains(task.bucket)
                } ?? false
            }
        )
    }

    private func row(_ step: CockpitOnboarding.Step, isDone: Bool, isCurrent: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isDone ? "checkmark.circle.fill" : (isCurrent ? "circle.dashed" : "circle"))
                .foregroundStyle(isDone ? Color.green : (isCurrent ? Color.accentColor : Color.secondary))
                .font(.system(size: 15))
                .accessibilityLabel(Text(isDone ? "Done" : "To do"))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Self.title(step))
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .strikethrough(isDone, color: .secondary)
                    .foregroundStyle(isDone ? .secondary : .primary)
                if isCurrent {
                    Text(verbatim: Self.explanation(step)).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if isCurrent, let action = action(for: step) {
                Button(String(localized: "Show me"), action: action)
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    /// Takes the person to the place the step happens. Nil when there is nowhere
    /// to go yet (no project with a decision to settle).
    private func action(for step: CockpitOnboarding.Step) -> (() -> Void)? {
        let firstProject = projects.summaries.first { $0.overview != nil } ?? projects.summaries.first
        switch step {
        case .openProject, .createPlan, .launchTask:
            guard let firstProject else { return nil }
            return {
                if step == .createPlan || step == .launchTask { cockpit.pendingProjectPlanPage = true }
                cockpit.destination = .project(path: firstProject.path)
            }
        case .followSession:
            return { cockpit.destination = .sessions }
        case .settleDecision:
            guard let withDecision = projects.summaries.first(where: { !$0.openDecisions.isEmpty }) else { return nil }
            return { cockpit.destination = .project(path: withDecision.path) }
        }
    }

    static func title(_ step: CockpitOnboarding.Step) -> String {
        switch step {
        case .openProject: String(localized: "onboarding.openProject", defaultValue: "Open a project")
        case .createPlan: String(localized: "onboarding.createPlan", defaultValue: "Create its plan")
        case .launchTask: String(localized: "onboarding.launchTask", defaultValue: "Launch an agent on a task")
        case .followSession: String(localized: "onboarding.followSession", defaultValue: "Follow the agent's session")
        case .settleDecision: String(localized: "onboarding.settleDecision", defaultValue: "Settle a decision")
        }
    }

    static func explanation(_ step: CockpitOnboarding.Step) -> String {
        switch step {
        case .openProject:
            String(localized: "onboarding.openProject.why",
                   defaultValue: "In the sidebar, under Projects, click the project you work on.")
        case .createPlan:
            String(localized: "onboarding.createPlan.why",
                   defaultValue: "Open Plan: Throttle proposes a starting plan for this project. Accept it.")
        case .launchTask:
            String(localized: "onboarding.launchTask.why",
                   defaultValue: "In Plan, pick a task marked Ready, then Launch (or Choose… to pick Claude or Codex).")
        case .followSession:
            String(localized: "onboarding.followSession.why",
                   defaultValue: "Open Sessions to watch the agent and answer its questions.")
        case .settleDecision:
            String(localized: "onboarding.settleDecision.why",
                   defaultValue: "When a decision waits on you, open it from Today and choose Settle.")
        }
    }
}
