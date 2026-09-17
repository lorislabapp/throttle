import SwiftUI
/// A project's task tree beside the selected task's log. The plan's authority is its log,
/// shows what happened rather than offering a second, conflicting way to say it.
struct PlanTreeView: View {
    let model: PlanModel
    var context = PlanViewContext()
    /// The cockpit opens the session; this view only asks for it.
    var onLaunch: ((TaskLauncher.LaunchPlan) -> Void)?
    var onShowSession: (() -> Void)?

    @State var launchError: String?
    /// Roles picked before launching, per task; absent means the suggested one.
    @State var launchRoles: [String: AgentRole] = [:]
    @State var integrationError: String?
    /// The task whose diff is open, if any.
    @State var expandedDiff: String?

    private let hair = Color.primary.opacity(0.10)

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                Rectangle().fill(hair).frame(height: 1)
                nextStepBanner
                Rectangle().fill(hair).frame(height: 1)
                tree
            }
            .frame(minWidth: 340)

            inspector
                .frame(minWidth: 260)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(model.plan?.title.uppercased() ?? "PLAN")
                    .font(.system(size: 11, weight: .semibold)).kerning(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.hasPlan {
                    Text("\(model.overallPct)%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Label(context.projectName, systemImage: "folder")
                    .font(.system(size: 12, weight: .semibold))
                Text(context.projectPath)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let session = context.sessionLabel {
                    HStack(spacing: 5) {
                        Image(systemName: "bubble.left.and.bubble.right")
                        Text(session)
                        if let runtime = context.runtime { Text("· \(runtime)") }
                        if let state = context.state { Text("· \(state)") }
                        Spacer(minLength: 4)
                        if onShowSession != nil {
                            Button("Show session") { onShowSession?() }
                                .buttonStyle(.link).controlSize(.small)
                        }
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                } else {
                    Text("No active session — this plan is not attached to a running agent.")
                        .font(.system(size: 10.5)).foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    // MARK: - Tree

    @ViewBuilder
    private var tree: some View {
        if let error = model.loadError {
            message("This project's plan could not be read.", detail: error)
        } else if !model.hasPlan {
            emptyPlan
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        taskRow(row)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selection = row.task.id }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Says what it saw before offering to act on it: a plan proposed without
    /// showing its reasoning is a plan the user has no way to judge.
    private var emptyPlan: some View {
        VStack(spacing: 10) {
            Text("No plan in this project")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)

            if let survey = model.survey {
                VStack(spacing: 3) {
                    ForEach(survey.observations, id: \.self) { line in
                        Text(line).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                Button(survey.shape == .empty
                       ? "Start from the idea" : "Start from what's here") {
                    model.bootstrap()
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func taskRow(_ row: PlanModel.Row) -> some View {
        let state = model.state(row.task.id)
        let selected = model.selection == row.task.id
        return HStack(spacing: 8) {
            Circle().fill(color(state.status)).frame(width: 6, height: 6)
                .padding(.leading, CGFloat(row.depth) * 14)

            Text(row.task.title)
                .font(.system(size: 12, weight: row.depth == 0 ? .semibold : .regular))
                .lineLimit(1)

            if !state.chainValid {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9)).foregroundStyle(.orange)
                    .help("This task's log was written outside Throttle — its hash chain does not verify.")
            }

            Spacer(minLength: 8)

            if let runtime = state.runtime, state.status != .candidate, state.status != .done,
               state.status != .failed {
                Text(verbatim: Self.runtimeName(runtime) ?? runtime)
                    .font(.system(size: 9, weight: .medium)).kerning(0.4)
                    .foregroundStyle(.secondary)
            }
            Text(statusText(state.status))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(color(state.status))
            if state.status == .blocked, let waiting = state.blockedReason {
                Text("waiting for \(waiting)").font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            progressBar(state.pct, status: state.status)
            Text("\(state.pct)%")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .background(selected ? Color.primary.opacity(0.06) : .clear)
    }

    private func progressBar(_ pct: Int, status: TaskStatus) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color(status))
                    .frame(width: geo.size.width * CGFloat(pct) / 100)
            }
        }
        .frame(width: 56, height: 4)
    }

    private func color(_ status: TaskStatus) -> Color {
        switch status {
        case .done, .integrated:    return .green
        case .failed:               return .red
        case .running, .claimed:    return .blue
        case .candidate, .review:   return .purple
        case .blocked:              return .orange
        case .pending:              return .secondary.opacity(0.5)
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        if let id = model.selection, let task = model.plan?.task(id) {
            let state = model.state(id)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(task.title).font(.system(size: 13, weight: .semibold))

                    nextAction(task, state)
                    facts(task, state)
                    designDetails(task)
                    productCycleDetails(task)

                    if !state.evidence.isEmpty {
                        section("EVIDENCE")
                        ForEach(Array(state.evidence.enumerated()), id: \.offset) { _, item in
                            Text("\(item.kind)  \(item.ref)")
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }

                    reviewDetails(state)

                    if !state.rejected.isEmpty {
                        section("REJECTED EVENTS")
                        ForEach(Array(state.rejected.enumerated()), id: \.offset) { _, item in
                            Text("seq \(item.seq)  \(item.author)  \(item.type.rawValue) — \(item.reason.rawValue)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let advice = model.advice[id] { recommendation(advice, taskID: id) }

                    integration(task, state)

                    section("LOG")
                    ForEach(model.events(for: id), id: \.seq) { event in
                        Text("\(event.seq)  \(event.author)  \(event.type.rawValue)"
                             + (event.pct.map { "  \($0)%" } ?? ""))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            // Assessing shells out to git, so it happens once when the selection or
            // the task's status changes — never while the inspector is drawing.
            .task(id: "\(id)/\(state.status.rawValue)") {
                await model.refreshAssessment(for: id)
            }
            // A refusal belongs to the task it was refused on, so it does not
            // follow the selection onto the next one. Both refusals: a failed launch
            // is no more the next task's business than a failed integration.
            .onChange(of: id) { _, _ in
                integrationError = nil
                launchError = nil
            }
        } else {
            message("Select a task.", detail: nil)
        }
    }

}
extension PlanTreeView {
    private func facts(_ task: PlanTask, _ state: TaskState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            fact("Status", statusText(state.status))
            fact("Progress", "\(state.pct)%")
            fact("Kind", task.kind.rawValue)
            if let owner = state.owner { fact("Held by", owner) }
            if let mission = state.missionID { fact("Mission", mission) }
            budgetFacts(state)
            if let hint = task.runtimeHint, state.owner == nil { fact("Suggested", hint) }
            if task.sotaGate {
                fact("Gate", String(localized: "SOTA — green verification requires review"))
            }
            if !task.dependsOn.isEmpty { fact("Depends on", task.dependsOn.joined(separator: ", ")) }
            if let summary = state.summary { fact("Summary", summary) }
            if state.rejectionCount > 0 {
                fact("Rejected", "\(state.rejectionCount)× of \(PlanProjection.maxRejections)")
            }
            if let judge = state.verdictBy { fact("Verdict by", judge) }
            if !state.chainValid { fact("Chain", String(localized: "does not verify")) }
        }
    }
    func fact(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 10, weight: .medium)).kerning(0.3)
                .foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            Text(value).font(.system(size: 11)).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func nextAction(_ task: PlanTask, _ state: TaskState) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            section("WHAT TO DO NOW")
            Text(nextStepText(task, state))
                .font(.system(size: 11.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            if let dependency = model.unmetDependencies(for: task).first,
               let dependencyTask = model.plan?.task(dependency) {
                Button("Open \(dependency): \(dependencyTask.title)") {
                    model.selection = dependency
                }
                .buttonStyle(.link).controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private func nextStepText(_ task: PlanTask, _ state: TaskState) -> String {
        if let dependency = model.unmetDependencies(for: task).first {
            let title = model.plan?.task(dependency)?.title ?? dependency
            return String(localized: "Finish \(dependency) — \(title) — before this task can start.")
        }
        switch state.status {
        case .pending:
            return String(localized: "Ready to start. Review the recommendation, then launch an agent.")
        case .claimed, .running:
            let runtime = Self.runtimeName(state.runtime) ?? String(localized: "the assigned")
            return String(localized: "Continue in \(runtime) session; it owns this task.")
        case .blocked:
            return state.blockedReason.map { String(localized: "Resolve the blocker: \($0)") }
                ?? String(localized: "Resolve the reported blocker.")
        case .candidate:
            return String(localized: "Run the declared verification. Only a green coordinator decision can finish it.")
        case .review:
            return String(localized: "Review the evidence with the opposite runtime before accepting completion.")
        case .done:
            return String(localized: "Review the diff and verification result, then integrate the task.")
        case .integrated:
            return String(localized: "Integrated. Select the next ready task in the plan.")
        case .failed:
            return String(localized: "Inspect the log, then release or retry this task explicitly.")
        }
    }
    private func statusText(_ status: TaskStatus) -> String {
        switch status {
        case .pending: return String(localized: "Ready")
        case .blocked: return String(localized: "Blocked")
        case .claimed: return String(localized: "Assigned")
        case .running: return String(localized: "Running")
        case .candidate: return String(localized: "Candidate")
        case .review: return String(localized: "Review")
        case .done: return String(localized: "Done")
        case .failed: return String(localized: "Failed")
        case .integrated: return String(localized: "Integrated")
        }
    }

    func section(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).kerning(0.5)
            .foregroundStyle(.secondary).padding(.top, 4)
    }

    private func message(_ title: LocalizedStringKey, detail: String?) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
