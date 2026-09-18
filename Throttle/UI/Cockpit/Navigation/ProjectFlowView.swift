import SwiftUI

/// A project as a pipeline: one sentence on what to look at, the columns work
/// moves through, and beside them the project's health and what just happened.
struct ProjectFlowView: View {
    let cockpit: MultiCockpitModel
    let overview: ProjectOverview
    let projectRoot: URL
    /// What each task has cost so far, measured from its own sessions.
    var spend: [String: TaskSpend.Entry] = [:]
    /// Opens the Plan page on a task.
    let openInPlan: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            focusBanner
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(PlanFlow.columns(overview)) { column in
                            FlowColumnView(column: column, cockpit: cockpit, spend: spend, openInPlan: openInPlan)
                        }
                    }
                    .padding(16)
                }
                Divider()
                FlowSidePanel(overview: overview, projectRoot: projectRoot, spend: spend,
                              openInPlan: openInPlan)
                    .frame(width: 260)
            }
        }
    }

    @ViewBuilder
    private var focusBanner: some View {
        let focus = PlanFlow.focus(overview)
        HStack(spacing: 10) {
            Image(systemName: focus.map { FlowWording.icon($0.stage) } ?? "checkmark.circle.fill")
                .font(.system(size: 18)).foregroundStyle(focus.map { FlowWording.tint($0.stage) } ?? .green)
            VStack(alignment: .leading, spacing: 2) {
                Text("NEXT STEP").font(.system(size: 9.5, weight: .semibold)).kerning(0.5).foregroundStyle(.secondary)
                Text(verbatim: focus.map { FlowWording.focusSentence($0.stage, $0.item) }
                     ?? String(localized: "Every task in this plan is done."))
                    .font(.system(size: 13, weight: .medium)).lineLimit(2)
            }
            Spacer(minLength: 8)
            if let focus {
                if [.working, .fixing].contains(focus.stage),
                   cockpit.hasSession(forMission: focus.item.state.missionID) {
                    Button("Show session") { cockpit.showSession(forMission: focus.item.state.missionID) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Open \(focus.item.id)") { openInPlan(focus.item.id) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color.accentColor.opacity(0.06))
    }
}

private struct FlowColumnView: View {
    let column: PlanFlow.Column
    let cockpit: MultiCockpitModel
    let spend: [String: TaskSpend.Entry]
    let openInPlan: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(FlowWording.tint(column.stage)).frame(width: 7, height: 7)
                Text(verbatim: FlowWording.title(column.stage)).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(verbatim: "\(column.cards.count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
            }
            .help(Text(verbatim: FlowWording.explanation(column.stage)))
            if column.cards.isEmpty {
                Text(verbatim: FlowWording.explanation(column.stage))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(column.cards) { item in card(item) }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 210, alignment: .topLeading)
        .frame(minHeight: 260, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func card(_ item: ProjectOverview.TaskItem) -> some View {
        let owned = cockpit.hasSession(forMission: item.state.missionID)
        return Button {
            if [.working, .fixing].contains(column.stage), owned {
                cockpit.showSession(forMission: item.state.missionID)
            } else {
                openInPlan(item.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: item.title).font(.system(size: 12, weight: .medium))
                    .lineLimit(3).multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(verbatim: item.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    if let runtime = PlanTreeView.runtimeName(item.state.runtime),
                       [.working, .fixing, .checking].contains(column.stage) {
                        Text(verbatim: runtime).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let entry = spend[item.id], entry.measured {
                        Text(verbatim: TaskSpend.format(entry.costEUR))
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .help(Text("Measured on this Mac, from this task's own sessions"))
                    }
                    if let since = item.lastActivity {
                        Text(since, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                if let note = FlowWording.cardNote(column.stage, item, hasSession: owned) {
                    Text(verbatim: note).font(.system(size: 10.5))
                        .foregroundStyle(column.stage == .fixing || column.stage == .waiting ? .orange : .secondary)
                        .lineLimit(2)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(FlowWording.tint(column.stage).opacity(0.35)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

private struct FlowSidePanel: View {
    let overview: ProjectOverview
    let projectRoot: URL
    let spend: [String: TaskSpend.Entry]
    let openInPlan: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                spendSection
                VStack(alignment: .leading, spacing: 8) {
                    header("HEALTH")
                    ForEach(PlanFlow.health(overview)) { check in
                        HStack(spacing: 7) {
                            Image(systemName: FlowWording.healthIcon(check.verdict))
                                .foregroundStyle(FlowWording.healthTint(check.verdict))
                            Text(verbatim: FlowWording.healthLabel(check)).font(.system(size: 12))
                        }
                    }
                }
                FlowLessonsSection(lessons: overview.lessons, projectRoot: projectRoot, openInPlan: openInPlan)
                VStack(alignment: .leading, spacing: 8) {
                    header("RECENT ACTIVITY")
                    if overview.changes.isEmpty {
                        Text("Nothing has moved yet.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(overview.changes) { change in
                        Button { openInPlan(change.taskID) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: "\(ProjectOverviewTab.eventVerb(change.event.type)) · \(change.taskID)")
                                    .font(.system(size: 12, weight: .medium))
                                Text(verbatim: change.taskTitle).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Text(change.event.timestamp, format: .relative(presentation: .named))
                                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
    }

    /// What the plan has cost so far. Tasks nobody measured are counted apart:
    /// an average over unknowns would read as a smaller bill, not a missing one.
    @ViewBuilder
    private var spendSection: some View {
        let total = TaskSpend.total(spend)
        if total.measured > 0 {
            VStack(alignment: .leading, spacing: 4) {
                header("SPENT ON THIS PLAN")
                Text(verbatim: TaskSpend.format(total.costEUR))
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                Text("\(total.measured) task(s) measured · \(total.unmeasured) without a session")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("API price of the tokens these sessions used. Not your subscription, and never added to it.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func header(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.system(size: 10.5, weight: .semibold)).kerning(0.5).foregroundStyle(.secondary)
    }
}
