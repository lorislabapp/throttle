import AppKit
import SwiftUI

/// A project's plan as an inbox beside the selected task's story (design 1b).
/// The plan's authority is its log: the detail retells it in sentences and keeps
/// the raw lines one disclosure away, rather than offering a second, conflicting
/// way to say what happened.
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
    /// The folded DONE line in the inbox.
    @State var showDone = false
    @State var rawLogOpen = false
    @State var detailsOpen = false
    /// Set by an inbox action that routes to a block in the detail.
    @State var scrollTarget: String?

    var body: some View {
        HSplitView {
            inboxPane
                .frame(minWidth: 340, idealWidth: 430)
            inspector
                .frame(minWidth: 320)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var inspector: some View {
        if let id = model.selection, let plan = model.plan, let task = plan.task(id) {
            let state = model.state(id)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        needsYouBanner(task, state)
                        detailBody(task, state, plan: plan)
                    }
                }
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    proxy.scrollTo(target, anchor: .top)
                    scrollTarget = nil
                }
            }
            // Assessing shells out to git, so it happens once when the selection or
            // the task's status changes — never while the inspector is drawing.
            .task(id: "\(id)/\(state.status.rawValue)") {
                await model.refreshAssessment(for: id)
            }
            // A refusal belongs to the task it was refused on, so it does not
            // follow the selection onto the next one.
            .onChange(of: id) { _, _ in
                integrationError = nil
                launchError = nil
                rawLogOpen = false
                detailsOpen = false
            }
        } else {
            message("Select a task.", detail: nil)
        }
    }

    private func detailBody(_ task: PlanTask, _ state: TaskState, plan: Plan) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            titleBlock(task, plan: plan)
            if let dependency = model.unmetDependencies(for: task).first,
               let dependencyTask = plan.task(dependency) {
                Button("Open \(PlanInbox.shortTitle(dependencyTask.title))") { model.selection = dependency }
                    .buttonStyle(.link).controlSize(.small)
            }
            evidenceCards(state)
            if let advice = model.advice[task.id], state.status == .pending {
                recommendation(advice, taskID: task.id).id(Anchor.recommendation.rawValue)
            }
            integration(task, state).id(Anchor.integration.rawValue)
            nextActionButton(task, state)
            reviewDetails(state)
            designDetails(task)
            productCycleDetails(task)
            whatHappened(task, state).id(Anchor.story.rawValue)
            if !state.rejected.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    section("REJECTED EVENTS")
                    ForEach(Array(state.rejected.enumerated()), id: \.offset) { _, item in
                        Text("seq \(item.seq)  \(item.author)  \(item.type.rawValue) — \(item.reason.rawValue)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            DisclosureGroup(isExpanded: $detailsOpen) {
                facts(task, state).padding(.top, 6)
            } label: {
                Text("Details — task id, mission, gate, held by").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 700, alignment: .leading)
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 24)
    }

    // MARK: - What happened

    @ViewBuilder
    private func whatHappened(_ task: PlanTask, _ state: TaskState) -> some View {
        let events = model.events(for: task.id)
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                section("WHAT HAPPENED")
                let chapters = PlanStory.chapters(events)
                ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                    chapterCard(chapter, state: state,
                                waitingSince: index == chapters.count - 1 ? waitingFooter(task, state, events) : nil)
                }
                if rawLogOpen {
                    Text(verbatim: events.map(Self.rawLine).joined(separator: "\n"))
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                        .lineSpacing(3).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                }
                Button { rawLogOpen.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: rawLogOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                        Text(state.chainValid
                             ? "Raw log · \(events.count) lines · hash chain verified"
                             : "Raw log · \(events.count) lines · hash chain does not verify")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(state.chainValid ? Color.accentColor : Self.amber)
                }
                .buttonStyle(.plain)
                .accessibilityValue(rawLogOpen ? Text("expanded") : Text("collapsed"))
            }
        }
    }

    private func chapterCard(_ chapter: PlanStory.Chapter, state: TaskState, waitingSince: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: chapter.actor.initial).font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
                    .frame(width: 18, height: 18)
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
                Text(verbatim: chapter.actor.name).font(.system(size: 12.5, weight: .semibold))
                Text(verbatim: [chapter.actor.session.map { String(localized: "session \($0)") },
                                PlanStory.span(chapter.start, chapter.end)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(chapter.events, id: \.seq) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: PlanStory.clock(event.timestamp))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .leading)
                        Text(verbatim: PlanStory.sentence(event, parkedForReview: state.status == .review))
                            .font(.system(size: 12.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
            if let waitingSince {
                HStack(spacing: 8) {
                    Circle().fill(Self.amber).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(verbatim: waitingSince).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Self.amber)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Self.amberFill)
                .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1) }
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    /// "Since 09:41 — waiting for you to hand it to Codex": only when a human is
    /// the blocker, dated by the last thing that happened.
    private func waitingFooter(_ task: PlanTask, _ state: TaskState, _ events: [TaskEvent]) -> String? {
        guard PlanInbox.group(for: state.status, unmetDependencies: model.unmetDependencies(for: task)) == .needsYou,
              state.status != .pending, let last = events.last else { return nil }
        let since = PlanStory.clock(last.timestamp)
        switch state.status {
        case .review:
            let reviewer = TaskReviewLauncher.reviewer(for: state.runtime).label
            return String(localized: "Since \(since) — waiting for you to hand it to \(reviewer)")
        case .done: return String(localized: "Since \(since) — waiting for you to integrate it")
        case .candidate: return String(localized: "Since \(since) — waiting for Throttle's check")
        default: return String(localized: "Since \(since) — waiting for you")
        }
    }

    static func rawLine(_ event: TaskEvent) -> String {
        var line = "\(event.seq)  \(event.author)  \(event.type.rawValue)"
        if let pct = event.pct { line += "  \(pct)%" }
        if let kind = event.kind { line += "  \(kind)" }
        if let ref = event.ref { line += "  \(ref)" }
        return line
    }

    /// Says what it saw before offering to act on it: a plan proposed without
    /// showing its reasoning is a plan the user has no way to judge.
    var emptyPlan: some View {
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

    func nextStepText(_ task: PlanTask, _ state: TaskState) -> String {
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
            guard model.declaredVerifyCommand(for: task.id) != nil else {
                return String(localized: """
                    This plan declares no check for this task, so Throttle cannot verify it yet. \
                    Add a verify line to the task in plan.json, then click Verify candidate.
                    """)
            }
            return String(localized: """
                Click Verify candidate below. Throttle runs the task's check; \
                only a green result can finish it.
                """)
        case .review:
            let reviewer = TaskReviewLauncher.reviewer(for: state.runtime)
            let builder = Self.runtimeName(state.runtime) ?? String(localized: "another runtime")
            return String(localized: """
                \(builder) did this work, so \(reviewer.label) has to judge it. \
                Launch the review: it reads the evidence and records its verdict here.
                """)
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

    func message(_ title: LocalizedStringKey, detail: String?) -> some View {
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
