import AppKit
import SwiftUI

// Design 1b "Inbox" (Claude Design, Plan Tab.dc.html): the left pane answers the
// five-second question — what is waiting on me? — with structure, not colour.
// Groups by who is blocking; finished work folds into one line; status is one
// shape, the ring. Amber appears only where a human is the blocker.
extension PlanTreeView {

    /// "A human is the blocker" — the only non-graphite status colour in the tab.
    static let amber = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.94, green: 0.63, blue: 0.24, alpha: 1)
            : NSColor(srgbRed: 0.60, green: 0.35, blue: 0.09, alpha: 1)
    })
    static let amberFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.94, green: 0.63, blue: 0.24, alpha: 0.16)
            : NSColor(srgbRed: 0.85, green: 0.51, blue: 0.17, alpha: 0.14)
    })

    // MARK: - Pane

    var inboxPane: some View {
        VStack(spacing: 0) {
            inboxHeader
            if let error = model.loadError {
                message("This project's plan could not be read.", detail: error)
            } else if let plan = model.plan {
                inboxGroups(PlanInbox.sections(plan: plan, states: model.states), plan: plan)
            } else {
                emptyPlan
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    private var inboxHeader: some View {
        HStack(spacing: 12) {
            if model.hasPlan {
                ProgressRing(fraction: Double(model.overallPct) / 100, lineWidth: 3.5)
                    .frame(width: 34, height: 34)
                    .accessibilityLabel(Text("\(model.overallPct) percent of the plan done"))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: model.plan?.title ?? String(localized: "Plan"))
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 0) {
                    if let plan = model.plan {
                        let sections = PlanInbox.sections(plan: plan, states: model.states)
                        Text(verbatim: "\(model.overallPct)%").font(.system(size: 11, design: .monospaced))
                        Text(" · \(sections.done.count) of \(sections.leafCount) done · \(context.projectName)")
                            .font(.system(size: 11))
                    } else {
                        Text(verbatim: context.projectName).font(.system(size: 11))
                    }
                }
                .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if onShowSession != nil, context.sessionLabel != nil {
                Button("Show session") { onShowSession?() }
                    .buttonStyle(.link).controlSize(.small)
                    .help(Text(verbatim: [context.sessionLabel, context.runtime, context.state]
                        .compactMap { $0 }.joined(separator: " · ")))
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
    }

    private func inboxGroups(_ sections: PlanInbox.Sections, plan: Plan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !sections.needsYou.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        groupLabel("NEEDS YOU", count: sections.needsYou.count, human: true)
                        ForEach(sections.needsYou) { task in needsYouCard(task, plan: plan) }
                    }
                }
                if !sections.agentsWorking.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        groupLabel("AGENTS WORKING", count: sections.agentsWorking.count, human: false)
                        ForEach(sections.agentsWorking) { task in compactRow(task, plan: plan) }
                    }
                }
                if !sections.waiting.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        groupLabel("WAITING", count: sections.waiting.count, human: false)
                        ForEach(sections.waiting) { task in compactRow(task, plan: plan) }
                    }
                }
                if !sections.done.isEmpty { doneFold(sections.done, plan: plan) }
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
    }

    private func groupLabel(_ title: LocalizedStringKey, count: Int, human: Bool) -> some View {
        HStack(spacing: 6) {
            if human { Circle().fill(Self.amber).frame(width: 7, height: 7).accessibilityHidden(true) }
            Text(title).font(.system(size: 10, weight: .semibold)).kerning(0.5)
                .foregroundStyle(human ? Self.amber : .secondary)
            Text(verbatim: "\(count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4).padding(.bottom, human ? 0 : 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Needs you: a card with its one action

    private func needsYouCard(_ task: PlanTask, plan: Plan) -> some View {
        let state = model.state(task.id)
        let selected = model.selection == task.id
        let action = inboxAction(task, state)
        return VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: task.title).font(.system(size: 12.5, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: cardSubtitle(task, state)).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                HStack(spacing: 8) {
                    actionButton(action, height: 26)
                    if let hint = action.hint {
                        Text(verbatim: hint).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(selected ? Color.primary : Color.primary.opacity(0.10), lineWidth: selected ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { model.selection = task.id }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(PlanInbox.shortTitle(task.title)) — \(cardSubtitle(task, state))"))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Working / waiting: one line each

    private func compactRow(_ task: PlanTask, plan: Plan) -> some View {
        let state = model.state(task.id)
        let selected = model.selection == task.id
        let working = state.status == .claimed || state.status == .running
        let trailing = rowTrailing(task, state, plan: plan)
        return HStack(spacing: 10) {
            if working {
                ProgressRing(fraction: Double(state.pct) / 100, lineWidth: 2)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(Text("\(state.pct) percent"))
            } else {
                Circle().strokeBorder(Color.primary.opacity(0.28), lineWidth: 1.5)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(Text("Waiting"))
            }
            Text(verbatim: task.title).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: trailing).font(.system(size: 11)).lineLimit(1).layoutPriority(1)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(working ? .primary : .secondary)
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(selected ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { model.selection = task.id }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(PlanInbox.shortTitle(task.title)) — \(trailing)"))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private func rowTrailing(_ task: PlanTask, _ state: TaskState, plan: Plan) -> String {
        switch state.status {
        case .claimed, .running:
            let who = Self.runtimeName(state.runtime) ?? String(localized: "An agent")
            guard let started = state.startedAt else { return who }
            return "\(who) · \(max(1, Int(Date().timeIntervalSince(started) / 60))) min"
        case .blocked:
            return state.blockedReason.map { String(localized: "blocked · \($0)") } ?? String(localized: "blocked")
        default:
            return PlanInbox.afterText(model.unmetDependencies(for: task), in: plan) ?? String(localized: "waiting")
        }
    }

    // MARK: - Done: folded to one line

    private func doneFold(_ done: [PlanTask], plan: Plan) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { showDone.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: showDone ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text("DONE").font(.system(size: 10, weight: .semibold)).kerning(0.5)
                    Text(verbatim: "\(done.count)").font(.system(size: 10, design: .monospaced))
                    if !showDone {
                        Text(verbatim: done.map { PlanInbox.shortTitle($0.title) }.joined(separator: " · "))
                            .font(.system(size: 11)).lineLimit(1).padding(.leading, 4)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showDone ? Text("expanded") : Text("collapsed"))
            if showDone {
                ForEach(done) { task in
                    HStack(spacing: 10) {
                        ProgressRing(fraction: 1, lineWidth: 2).frame(width: 16, height: 16)
                            .accessibilityLabel(Text("Done"))
                        Text(verbatim: task.title).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 7)
                    .background(model.selection == task.id ? Color.primary.opacity(0.06) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { model.selection = task.id }
                    .accessibilityAddTraits(.isButton)
                }
            }
        }
    }
}

/// Status as one shape: full = done, partial = agent progress, empty = waiting.
/// A trimmed circle, not Canvas or a conic gradient (macOS 26.5 guardrails); static.
struct ProgressRing: View {
    var fraction: Double
    var lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.10), lineWidth: lineWidth)
            Circle().trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(Color.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}
