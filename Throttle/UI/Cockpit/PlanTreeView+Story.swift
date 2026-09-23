import AppKit
import SwiftUI

// The detail half of design 1b: a banner with the one button when a human is the
// blocker, a meta line in words, evidence as cards, and the log told as a story.
// The integration and launch blocks below keep their own warnings and disabled
// reasons — the inbox only ever routes to them, it never bypasses them.
extension PlanTreeView {

    /// The one action a task needs from its person. Shared by the inbox card and
    /// the detail banner, so the same task never offers two different buttons.
    struct InboxAction {
        var title: String
        var prominent: Bool
        var hint: String?
        var run: () -> Void
    }

    /// Scroll anchors inside the detail.
    enum Anchor: String { case integration, recommendation, story }

    func inboxAction(_ task: PlanTask, _ state: TaskState) -> InboxAction? {
        switch state.status {
        case .review:
            let reviewer = TaskReviewLauncher.reviewer(for: state.runtime)
            let items = state.evidence.count
            return InboxAction(
                title: String(localized: "Ask \(reviewer.label) to review"), prominent: true,
                hint: items > 0 ? String(localized: "\(items) evidence items") : nil
            ) { model.selection = task.id; launchReview(taskID: task.id, runtime: reviewer) }
        case .done:
            // Routed to the integration block: its trust warning and blocked
            // reasons are the point, and a one-click merge would skip both.
            return InboxAction(
                title: String(localized: "Integrate"), prominent: false,
                hint: model.verifyCommand(for: task.id).map { String(localized: "runs \($0) first") }
            ) { reveal(task.id, .integration) }
        case .candidate:
            if model.declaredVerifyCommand(for: task.id) == nil, let url = model.planFileURL {
                return InboxAction(title: String(localized: "Open plan.json"), prominent: false,
                                   hint: String(localized: "no check declared")) { NSWorkspace.shared.open(url) }
            }
            return InboxAction(title: String(localized: "Verify candidate"), prominent: false, hint: nil) {
                reveal(task.id, .integration)
            }
        case .failed:
            return InboxAction(title: String(localized: "Read what failed"), prominent: false, hint: nil) {
                reveal(task.id, .story)
            }
        case .pending where model.unmetDependencies(for: task).isEmpty:
            guard let advice = model.advice[task.id], let runtime = advice.runtime else {
                return InboxAction(title: String(localized: "Choose who runs it"), prominent: false, hint: nil) {
                    reveal(task.id, .recommendation)
                }
            }
            // The multiplier is the number that costs money: stated beside the button.
            let cost = advice.tokenMultiplier.map {
                String(localized: "≈\($0.formatted(.number.precision(.fractionLength(0))))× tokens")
            }
            return InboxAction(title: String(localized: "Launch with \(runtime.label)"), prominent: true,
                               hint: cost) { model.selection = task.id; launch(taskID: task.id, runtime: runtime) }
        default:
            return nil
        }
    }

    func reveal(_ taskID: String, _ anchor: Anchor) {
        model.selection = taskID
        scrollTarget = anchor.rawValue
    }

    func actionButton(_ action: InboxAction, height: CGFloat) -> some View {
        Button(action: action.run) {
            Text(verbatim: action.title).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 11).frame(height: height)
                .foregroundStyle(action.prominent ? Color.white : Color.accentColor)
                .background(action.prominent ? Color.accentColor : Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(action.prominent ? .clear : Color.primary.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(model.integrationStep != .idle && !action.prominent)
    }

    /// What the card says under the title: who finished, who is missing.
    func cardSubtitle(_ task: PlanTask, _ state: TaskState) -> String {
        switch state.status {
        case .review:
            let builder = Self.runtimeName(state.runtime) ?? String(localized: "An agent")
            let reviewer = TaskReviewLauncher.reviewer(for: state.runtime)
            return String(localized: "\(builder) finished · \(reviewer.label) hasn't reviewed")
        case .done:
            var parts = [state.verdictBy.map { String(localized: "Verified by \(PlanStory.actor($0).name)") }
                         ?? String(localized: "Verified")]
            if let assessment = model.assessment(for: task.id) {
                if case .clean = assessment.mergeability { parts.append(String(localized: "merges cleanly")) }
                parts.append(Self.shapeText(assessment))
            }
            return parts.joined(separator: " · ")
        case .candidate: return String(localized: "Finished · waiting for Throttle's check")
        case .failed: return String(localized: "Failed · open it to read why")
        default: return String(localized: "Ready to start")
        }
    }

    static func shapeText(_ assessment: Assessment) -> String {
        let added = assessment.files.reduce(0) { $0 + $1.added }
        let removed = assessment.files.reduce(0) { $0 + $1.removed }
        return String(localized: "\(assessment.files.count) files +\(added) −\(removed)")
    }

    // MARK: - Banner

    @ViewBuilder
    func needsYouBanner(_ task: PlanTask, _ state: TaskState) -> some View {
        if PlanInbox.group(for: state.status, unmetDependencies: model.unmetDependencies(for: task)) == .needsYou,
           let action = inboxAction(task, state) {
            HStack(spacing: 12) {
                Circle().fill(Self.amber).frame(width: 8, height: 8).accessibilityHidden(true)
                (Text(verbatim: bannerHeadline(state)).fontWeight(.semibold)
                 + Text(verbatim: " " + nextStepText(task, state)).foregroundColor(.secondary))
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actionButton(action, height: 28)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Needs you"))
            if let launchError {
                Text(launchError).font(.system(size: 11)).foregroundStyle(.red)
                    .padding(.horizontal, 20).padding(.top, 6)
            }
        }
    }

    private func bannerHeadline(_ state: TaskState) -> String {
        switch state.status {
        case .review:
            let reviewer = TaskReviewLauncher.reviewer(for: state.runtime)
            return String(localized: "\(reviewer.label) must review this before it counts.")
        case .done: return String(localized: "Ready to integrate.")
        case .candidate: return String(localized: "Waiting for Throttle's check.")
        case .failed: return String(localized: "This task failed.")
        default: return String(localized: "Ready to start.")
        }
    }

    // MARK: - Title + meta

    func titleBlock(_ task: PlanTask, plan: Plan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: task.title).font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: metaLine(task, plan: plan)).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Research · Viability · after List what is unfinished ✓ · unblocks What their users…"
    private func metaLine(_ task: PlanTask, plan: Plan) -> String {
        var parts = [task.kind.rawValue.capitalized]
        if let parent = task.parent.flatMap(plan.task) { parts.append(parent.title) }
        let unmet = Set(model.unmetDependencies(for: task))
        for dep in task.dependsOn {
            let name = plan.task(dep).map { PlanInbox.shortTitle($0.title) } ?? dep
            parts.append(unmet.contains(dep) ? String(localized: "after \(name)")
                                             : String(localized: "after \(name) ✓"))
        }
        let unblocks = PlanInbox.dependents(of: task.id, in: plan)
        if unblocks.count == 1 {
            parts.append(String(localized: "unblocks \(PlanInbox.shortTitle(unblocks[0].title))"))
        } else if unblocks.count > 1 {
            parts.append(String(localized: "unblocks \(unblocks.count) tasks"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Evidence

    @ViewBuilder
    func evidenceCards(_ state: TaskState) -> some View {
        if !state.evidence.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                section("EVIDENCE · \(state.evidence.count)")
                ForEach(Array(state.evidence.enumerated()), id: \.offset) { _, item in
                    evidenceCard(item)
                }
            }
        }
    }

    private func evidenceCard(_ item: TaskEvidence) -> some View {
        let file = evidenceFile(item)
        let isCommit = item.kind == "commit"
        return HStack(spacing: 12) {
            Image(systemName: isCommit ? "point.topleft.down.to.point.bottomright.curvepath" : "doc.text")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: PlanStory.evidenceName(kind: item.kind, ref: item.ref))
                    .font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(verbatim: evidenceSubtitle(item, file: file)).font(.system(size: 11))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let file {
                smallButton("Open") { NSWorkspace.shared.open(file) }
            } else if isCommit {
                smallButton("Copy SHA") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.ref, forType: .string)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    /// A report or file evidence that exists on disk, resolved against the project.
    private func evidenceFile(_ item: TaskEvidence) -> URL? {
        guard item.kind != "commit", item.kind != "test" else { return nil }
        let url = item.ref.hasPrefix("/") ? URL(fileURLWithPath: item.ref)
            : model.root.map { $0.appendingPathComponent(item.ref) }
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func evidenceSubtitle(_ item: TaskEvidence, file: URL?) -> String {
        var parts = [item.kind.capitalized]
        if item.kind == "commit" { parts.append(String(item.ref.prefix(12))) }
        if let file, let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        parts.append(String(localized: "added \(PlanStory.clock(item.timestamp))"))
        return parts.joined(separator: " · ")
    }

    private func smallButton(_ title: LocalizedStringKey, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10).frame(height: 24)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
