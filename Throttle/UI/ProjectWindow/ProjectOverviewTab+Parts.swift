import SwiftUI

extension ProjectOverviewTab {

    // MARK: Building blocks

    func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.10)))
    }

    func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).textCase(.uppercase).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    func cardHeader(_ title: LocalizedStringKey, trailing: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            sectionTitle(title)
            Spacer()
            if let trailing {
                Text(verbatim: trailing).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }

    /// A row that opens its inspector in place, as a popover on the row itself.
    func nodeButton<Label: View, Inspector: View>(
        id: String, @ViewBuilder label: () -> Label, @ViewBuilder inspector: @escaping () -> Inspector
    ) -> some View {
        let isOpen = Binding(get: { inspected == id }, set: { if !$0, inspected == id { inspected = nil } })
        return Button { inspected = id } label: {
            label()
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(inspected == id ? Color.accentColor.opacity(0.10) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .popover(isPresented: isOpen, arrowEdge: .leading) { inspector() }
        .accessibilityAddTraits(inspected == id ? .isSelected : [])
    }

    func inspector(kind: String, id: String, title: String, status: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "\(kind) · \(id)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            Text(verbatim: title).font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: status).font(.system(size: 12))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(verbatim: row.0).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Text(verbatim: row.1).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    /// "Show in Cockpit" needs a session working in this project, because the
    /// Plan view reads its project from the active session; without one the
    /// button says why it cannot help instead of opening another project's plan.
    func inspectorActions(taskID: String, settle decision: ProjectOverview.Decision?) -> some View {
        let root = resolvedRoot ?? project.url
        let cockpit = MultiCockpitModel.shared
        let hasSession = root != nil
        return HStack(spacing: 8) {
            Button("Show in Cockpit") {
                guard let root, cockpit.focusPlan(projectRoot: root, taskID: taskID) else { return }
                inspected = nil
                CockpitWindowController.shared.show(appState: appState)
            }
            .disabled(!hasSession)
            .help(Text("Opens the Plan view on this task."))
            if let decision {
                Button("Settle…") {
                    inspected = nil
                    settling = decision
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.small)
        .padding([.horizontal, .bottom], 14)
    }

    func taskInspector(_ task: ProjectOverview.TaskItem) -> some View {
        let state = task.state
        var rows: [(String, String)] = []
        if let sha = state.integratedSHA { rows.append((String(localized: "SHA"), String(sha.prefix(7)))) }
        if let check = state.lastCheck {
            let result = check.passed ? String(localized: "passed") : String(localized: "failed")
            rows.append((String(localized: "Last check"), result))
            rows.append((String(localized: "Ran"), Self.shortDateTime(check.ranAt)))
        }
        if let review = state.lastReview { rows.append((String(localized: "Reviewer"), review.reviewerKind.rawValue)) }
        if let reason = state.blockedReason { rows.append((String(localized: "Reason"), reason)) }
        if let owner = state.owner { rows.append((String(localized: "Owner"), owner)) }
        if state.lastCheck == nil { rows.append((String(localized: "Evidence"), String(localized: "— (no receipt)"))) }
        return inspector(kind: String(localized: "Task"), id: task.id, title: task.title,
                         status: Self.bucketWord(task.bucket), rows: rows)
    }

    // MARK: Wording

    static func bucketWord(_ bucket: ProjectOverview.Bucket) -> String {
        switch bucket {
        case .integrated: String(localized: "overview.bucket.integrated", defaultValue: "Integrated")
        case .verified: String(localized: "overview.bucket.verified", defaultValue: "Verified")
        case .candidate: String(localized: "overview.bucket.candidate", defaultValue: "Awaiting review")
        case .inProgress: String(localized: "overview.bucket.inProgress", defaultValue: "In progress")
        case .blocked: String(localized: "overview.bucket.blocked", defaultValue: "Blocked")
        case .failed: String(localized: "overview.bucket.failed", defaultValue: "Failed")
        case .pending: String(localized: "overview.bucket.pending", defaultValue: "Not started")
        }
    }

    static func tint(_ bucket: ProjectOverview.Bucket) -> Color {
        switch bucket {
        case .integrated: .accentColor
        case .verified: .green
        case .candidate: .secondary.opacity(0.6)
        case .inProgress: .secondary
        case .blocked: ResearchVaultWorkbenchView.driftTint
        case .failed: .red
        case .pending: .primary.opacity(0.12)
        }
    }

    func bucketIcon(_ bucket: ProjectOverview.Bucket) -> some View {
        let symbol = switch bucket {
        case .integrated: "arrow.triangle.merge"
        case .verified: "checkmark.seal.fill"
        case .candidate: "clock"
        case .inProgress: "circle.lefthalf.filled"
        case .blocked: "nosign"
        case .failed: "xmark.circle.fill"
        case .pending: "circle"
        }
        return Image(systemName: symbol)
            .foregroundStyle(bucket == .pending ? Color.secondary : Self.tint(bucket))
            .frame(width: 16)
            .accessibilityLabel(Text(verbatim: Self.bucketWord(bucket)))
    }

    static func taskShort(_ task: ProjectOverview.TaskItem) -> String {
        if let sha = task.state.integratedSHA { return String(sha.prefix(7)) }
        if let receipt = task.state.lastCheck?.receipt, let expected = receipt.expectedTests?.count {
            return "\(receipt.passedTests?.count ?? 0)/\(expected)"
        }
        return task.bucket == .blocked || task.bucket == .failed ? task.id : "—"
    }

    static func decisionLine(_ decision: ProjectOverview.Decision) -> String {
        guard let opened = decision.openedAt else { return bucketWord(decision.bucket) }
        return String(localized: "\(bucketWord(decision.bucket)) · open since \(shortDate(opened))")
    }

    static func eventVerb(_ type: TaskEventType) -> String {
        switch type {
        case .integrated: String(localized: "overview.event.integrated", defaultValue: "Integrated")
        case .verified: String(localized: "overview.event.verified", defaultValue: "Verified")
        case .rejected: String(localized: "overview.event.rejected", defaultValue: "Rejected")
        case .blocked: String(localized: "overview.event.blocked", defaultValue: "Blocked")
        case .unblocked: String(localized: "overview.event.unblocked", defaultValue: "Unblocked")
        case .failed: String(localized: "overview.event.failed", defaultValue: "Failed")
        default: type.rawValue
        }
    }

    static func proofSymbol(_ outcome: ProjectOverview.ProofOutcome) -> String {
        switch outcome {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .incomplete: "circle.bottomhalf.filled"
        }
    }

    static func proofTint(_ outcome: ProjectOverview.ProofOutcome) -> Color {
        switch outcome {
        case .passed: .green
        case .failed: .red
        case .incomplete: ResearchVaultWorkbenchView.driftTint
        }
    }

    static func proofWord(_ outcome: ProjectOverview.ProofOutcome) -> String {
        switch outcome {
        case .passed: String(localized: "overview.proof.passed", defaultValue: "Passed")
        case .failed: String(localized: "overview.proof.failed", defaultValue: "Failed")
        case .incomplete: String(localized: "overview.proof.incomplete", defaultValue: "Incomplete")
        }
    }

    static func testsLine(_ proof: ProjectOverview.Proof) -> String {
        guard let expected = proof.expected else { return "—" }
        return "\(proof.passed ?? 0)/\(expected)"
    }

    static func figureValue(_ figure: ProjectCostReadout.Figure) -> String {
        switch figure {
        case .known(let value), .estimated(let value): value
        case .unmeasured: "—"
        }
    }

    static func figureIsMeasured(_ figure: ProjectCostReadout.Figure) -> Bool {
        if case .unmeasured = figure { return false }
        return true
    }

    static func figureKind(_ figure: ProjectCostReadout.Figure) -> String {
        switch figure {
        case .known: String(localized: "overview.cost.known", defaultValue: "known")
        case .estimated: String(localized: "overview.cost.estimated", defaultValue: "estimated")
        case .unmeasured: String(localized: "overview.cost.unmeasured", defaultValue: "not measured")
        }
    }

    static func shortDate(_ date: Date) -> String { date.formatted(date: .numeric, time: .omitted) }
    static func shortDateTime(_ date: Date) -> String { date.formatted(date: .numeric, time: .shortened) }
}
