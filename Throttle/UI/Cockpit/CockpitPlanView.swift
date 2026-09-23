import SwiftUI

/// Repository-wide screens that do not require a live terminal session.
struct CockpitSpecialView: View {
    let cockpit: MultiCockpitModel

    static func icon(for mode: MultiCockpitModel.ViewMode) -> String {
        mode == .plan ? "list.bullet.indent" : "point.3.filled.connected.trianglepath.dotted"
    }

    @ViewBuilder var body: some View {
        if cockpit.viewMode == .plan {
            CockpitPlanView(cockpit: cockpit)
        } else {
            PortfolioGraphView()
        }
    }
}

/// A plan belongs to a repository, not to a live session. Keeping this binding
/// outside `MultiCockpitRoot` also prevents one feature from growing that legacy
/// view's already-large body.
struct CockpitPlanView: View {
    let cockpit: MultiCockpitModel
    /// A project page shows its own plan whatever session is active; nil keeps
    /// the historical behaviour of following the active session's folder.
    var fixedProjectRoot: URL?
    @State private var planModel = PlanModel()
    @State private var showInstructions = false

    var body: some View {
        VStack(spacing: 0) {
            if activeProjectRoot != nil {
                HStack {
                    Spacer()
                    Button("Project Instructions", systemImage: "doc.badge.gearshape") {
                        showInstructions = true
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                Divider()
            }
            PlanTreeView(
                model: planModel,
                context: context,
                onLaunch: launch,
                onShowSession: showActiveSession
            )
        }
            .onAppear {
                planModel.onAutoRelaunch = launch
                planModel.isDirectoryHeldBySession = {
                    SessionWorkingDirectory.isSessionWorking(inside: $0, of: cockpit.sessions)
                }
                planModel.bind(to: activeProjectRoot)
                planModel.orient(to: cockpit.active?.missionID)
                applyPendingSelection()
            }
            .onChange(of: cockpit.activeID) { _, _ in
                planModel.bind(to: activeProjectRoot)
                planModel.orient(to: cockpit.active?.missionID)
                applyPendingSelection()
            }
            .onChange(of: cockpit.pendingPlanSelection) { _, _ in applyPendingSelection() }
            .sheet(isPresented: $showInstructions) {
                if let root = activeProjectRoot {
                    ProjectInstructionReviewView(projectRoot: root)
                }
            }
    }

    /// A selection asked for from outside (the project overview) wins over the
    /// orientation the view would pick by itself, once.
    private func applyPendingSelection() {
        guard let taskID = cockpit.pendingPlanSelection else { return }
        planModel.selection = taskID
        cockpit.pendingPlanSelection = nil
    }

    private func launch(_ task: TaskLauncher.LaunchPlan) {
        cockpit.newSession(
            projectName: task.taskID,
            cwd: task.workingDirectory.path,
            runtime: task.runtime,
            missionID: task.missionID,
            initialPrompt: task.kickoff,
            launchEnvironment: [PlanMCPAuthority.environmentKey + "=" + task.authorityDescriptor.path]
        )
    }

    private var activeProjectRoot: URL? {
        if let fixedProjectRoot { return fixedProjectRoot }
        guard let cwd = cockpit.active?.cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd, isDirectory: true)
    }

    /// The session this plan is about: on a project page, one working in that
    /// project (never whichever session happens to be active elsewhere).
    private var contextSession: CockpitTab? {
        guard let fixedProjectRoot else { return cockpit.active }
        let root = fixedProjectRoot.standardizedFileURL.path
        let inProject = CockpitProjectsModel.shared.sessions(in: root, from: cockpit)
        return taskOwnerSession ?? inProject.first { $0.id == cockpit.activeID }
            ?? inProject.first { $0.isLive } ?? inProject.first
    }

    /// The session that launched the task in progress: "Show session" must open
    /// the agent doing the work, not whichever tab sits in the same folder.
    private var taskOwnerSession: CockpitTab? {
        let missions = Set(planModel.states.values.filter { [.claimed, .running].contains($0.status) }
            .compactMap(\.missionID))
        if let selection = planModel.selection, let mission = planModel.state(selection).missionID,
           let owner = cockpit.sessions.first(where: { $0.missionID.uuidString == mission }) {
            return owner
        }
        return cockpit.sessions.first { missions.contains($0.missionID.uuidString) }
    }

    private var context: PlanViewContext {
        guard let active = contextSession else {
            guard let fixedProjectRoot else { return PlanViewContext() }
            return PlanViewContext(projectName: fixedProjectRoot.lastPathComponent,
                                   projectPath: fixedProjectRoot.path,
                                   sessionLabel: String(localized: "No session open in this project"))
        }
        // A session running in a worktree is named after the worktree ("T1.1");
        // on a project page the project is the one the page is about.
        return PlanViewContext(
            projectName: fixedProjectRoot?.lastPathComponent ?? active.projectName,
            projectPath: fixedProjectRoot?.path ?? active.cwd,
            sessionLabel: "Session \((active.sessionId ?? active.id.uuidString).prefix(8))",
            runtime: active.runtime.label,
            state: sessionState(active)
        )
    }

    private func showActiveSession() {
        guard let session = contextSession else { return }
        cockpit.activeID = session.id
        cockpit.wake(session.id)
        cockpit.destination = .sessions
        cockpit.viewMode = .rail
    }

    private func sessionState(_ session: CockpitTab) -> String {
        switch session.state {
        case .dormant: return String(localized: "not started")
        case .hibernated: return String(localized: "hibernated")
        case .rateLimited: return String(localized: "rate limited")
        case .paused: return String(localized: "paused")
        case .working: return String(localized: "working")
        case .waiting: return String(localized: "waiting for you")
        case .idle: return String(localized: "idle")
        }
    }
}
