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

// The block that writes to the base branch, kept out of the tree view for the same
// reason as the recommendation: the part that changes the repository reads on its
// own.
//
// Nothing here shells out to git. The assessment and the diff are read into the
// model — on selection, and on opening the disclosure — because a `body` runs on
// every draw and git does not belong there.
extension PlanTreeView {

    @ViewBuilder
    private func contractStatus(_ task: PlanTask, _ state: TaskState, _ assessment: Assessment) -> some View {
        if let contract = task.effectiveVerificationContract {
            Text(contract.accepts(state.lastCheck?.receipt, stamp: assessment.stamp)
                 && state.lastCheck?.passed == true
                 ? String(localized: "Required tests verified for this revision")
                 : String(localized: "Required tests awaiting valid evidence"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    func integration(_ task: PlanTask, _ state: TaskState) -> some View {
        if state.status == .integrated {
            integratedStatus(task, state)
        } else if state.status == .candidate || state.status == .done,
                  let assessment = model.assessment(for: task.id) {
            VStack(alignment: .leading, spacing: 6) {
                section("INTEGRATION")
                shape(assessment)
                mergeNotice(assessment)
                if let command = model.verifyCommand(for: task.id) {
                    Text("verify: \(command)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                controls(task.id, assessment)
                contractStatus(task, state, assessment)
                if let check = state.lastCheck {
                    Text(check.receipt == nil
                         ? String(localized: "Historical check — evidence coverage not recorded")
                         : String(localized:
                            "Command-level evidence — test coverage and physical acceptance are separate"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let integrationError {
                    Text(integrationError).font(.system(size: 11)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                diffDisclosure(task.id)
            }
        } else if state.status == .candidate || state.status == .done,
                  let reason = model.assessmentError(for: task.id) {
            // A `done` task the user is looking for the button on, and there is a
            // reason there isn't one. Saying it is the whole point: the card used to
            // render as an empty space, which reads as Throttle having forgotten.
            VStack(alignment: .leading, spacing: 4) {
                section("INTEGRATION")
                Text(reason).font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func integratedStatus(_ task: PlanTask, _ state: TaskState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            section("INTEGRATED")
            Text(state.integratedSHA.map { String($0.prefix(10)) } ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            if let kept = model.keptWorktreePath(for: task.id) {
                Text("Worktree kept").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(kept).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    /// What the task touched, before anything about whether it merges.
    private func shape(_ assessment: Assessment) -> some View {
        Text("\(assessment.files.count) file(s)  "
             + "+\(assessment.files.reduce(0) { $0 + $1.added })  "
             + "−\(assessment.files.reduce(0) { $0 + $1.removed })")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func mergeNotice(_ assessment: Assessment) -> some View {
        switch assessment.mergeability {
        case .clean:
            if assessment.behindBy > 0 {
                Text("\(assessment.behindBy) commit(s) behind — will rebase first")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .conflicted(let paths):
            // A quarter of agent branches land here, so it is a state with named
            // files, not an error to apologise for.
            Text("Conflicts with the base in:")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
            ForEach(paths, id: \.self) { path in
                Text("· \(path)").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.orange)
            }
        case .unknown:
            // Says so without disabling the button: the sequence always rebases
            // first, and a rebase is git's own answer to the question this git
            // could not precompute.
            Text("This git cannot say whether it merges cleanly (needs 2.38).")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    /// One button. It names the step it is on, so a verification that takes minutes
    /// reads as work rather than as a hang — and when it is disabled, the line under
    /// it says why. A disabled control with no reason is the one thing this card
    /// avoids everywhere else.
    private func controls(_ taskID: String, _ assessment: Assessment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            buttons(taskID, assessment)
            if let reason = Self.blockReason(assessment) {
                Text(reason).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func buttons(_ taskID: String, _ assessment: Assessment) -> some View {
        HStack(spacing: 8) {
            Button(model.integrationStep == .idle
                   ? (model.state(taskID).status == .candidate
                        ? String(localized: "Verify candidate")
                        : String(localized: "Integrate"))
                   : model.integrationStep.rawValue.capitalized) {
                // The previous refusal goes before the new attempt, not after it:
                // old red text under a button reading "Rebasing" describes nothing.
                integrationError = nil
                Task {
                    let outcome = await model.integrate(taskID: taskID)
                    // A verification runs for minutes, and the user is free to look
                    // elsewhere meanwhile. A refusal that belongs to a card nobody
                    // is on is dropped rather than pinned under the next task — the
                    // failed `checked` event is in that task's own log either way.
                    guard model.selection == taskID else { return }
                    integrationError = outcome
                }
            }
            .controlSize(.small)
            .disabled(model.integrationStep != .idle || Self.blocked(assessment))

            // Only on the tasks that would actually face this prompt — the pending
            // command is one value, but it is not every task's command.
            if model.pendingVerifyCommand != nil,
               model.pendingVerifyCommand == model.verifyCommand(for: taskID) {
                Button("Allow this command") {
                    model.allowVerifyCommand()
                    integrationError = nil
                }
                .controlSize(.small)
            }
        }
    }

    /// The diff is fetched when it is opened, not on every draw. Keying the
    /// expansion on the task id also closes it when the selection moves.
    private func diffDisclosure(_ taskID: String) -> some View {
        let isOpen = Binding(
            get: { expandedDiff == taskID },
            set: { open in
                expandedDiff = open ? taskID : nil
                if open { Task { await model.refreshDiff(for: taskID) } }
            })
        return DisclosureGroup("Diff", isExpanded: isOpen) {
            ScrollView(.horizontal) {
                Text(model.integrationDiff(for: taskID))
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 260)
        }
        .font(.system(size: 11))
    }

    /// Conflicts and loose changes are the two things no click can push through.
    static func blocked(_ assessment: Assessment) -> Bool { blockReason(assessment) != nil }

    /// Why the button is disabled, in the user's terms — nil when it is not.
    ///
    /// `hasLooseWork`, not `isDirty`: the untracked-inclusive view is what a `.build/`
    /// directory left by the last verification trips, and reading it here disabled the
    /// button with no explanation and nothing the user could do from the card. The
    /// service refuses on tracked modifications only, so this reads the same thing.
    static func blockReason(_ assessment: Assessment) -> String? {
        if case .conflicted = assessment.mergeability {
            return String(localized: """
            Blocked: the files above conflict with the base. Resolve them in the \
            worktree and commit, then this can merge.
            """)
        }
        if assessment.hasLooseWork {
            return String(localized: """
            Blocked: the worktree has uncommitted changes to tracked files. Commit or \
            discard them in it first.
            """)
        }
        return nil
    }
}
