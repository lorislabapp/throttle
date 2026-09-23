import SwiftUI

extension ProjectOverviewTab {

    // MARK: Objective

    func objectiveCard(_ overview: ProjectOverview) -> some View {
        card {
            cardHeader("Objective", trailing: overview.objective?.contractRevision.map {
                String(localized: "contract rev. \($0)")
            })
            if let objective = overview.objective {
                Text(objective.text).font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                ForEach(objective.requirements, id: \.id) { requirement in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(requirement.blocking ? "Blocking" : "Not blocking")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(requirement.blocking ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .frame(width: 92, alignment: .leading)
                        Text(requirement.statement).font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text(verbatim: overview.planTitle).font(.system(size: 15, weight: .semibold))
                Text("No task carries a work contract yet, so there is no stated objective to show.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Progress

    func progressCard(_ overview: ProjectOverview) -> some View {
        let progress = overview.progress
        return card {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("Verified progress")
                Spacer()
                Text(verbatim: "\(progress.proven) / \(progress.total)")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            progressBar(progress)
            progressLegend(progress)
            // The agents' own percentage is deliberately absent: it is not verification.
            Text("The agents' self-reported % is not shown here: it is not verification.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(overview.tasks) { task in
                    nodeButton(id: task.id) {
                        HStack(spacing: 8) {
                            bucketIcon(task.bucket)
                            Text(verbatim: task.title).font(.system(size: 13)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(verbatim: Self.taskShort(task))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    } inspector: {
                        VStack(alignment: .leading, spacing: 0) {
                            taskInspector(task)
                            inspectorActions(taskID: task.id, settle: nil)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(
            "Verified progress: \(progress.proven) of \(progress.total) tasks integrated or verified."
        ))
    }

    /// Every status with a count, each with its symbol, so the bar is never read by colour alone.
    private func progressLegend(_ progress: ProjectOverview.Progress) -> some View {
        HStack(spacing: 12) {
            ForEach(ProjectOverview.Bucket.allCases.filter { $0 != .pending && progress.count($0) > 0 },
                    id: \.self) { bucket in
                HStack(spacing: 4) {
                    bucketIcon(bucket)
                    Text(verbatim: "\(progress.count(bucket)) \(Self.bucketWord(bucket).lowercased())")
                }
            }
        }
        .font(.system(size: 11.5).monospacedDigit())
        .foregroundStyle(.secondary)
    }

    /// The SHA an integration landed as, or the reason a rejection or block gave.
    static func changeDetail(_ change: ProjectOverview.Change) -> String? {
        switch change.event.type {
        case .integrated: change.event.ref.map { String($0.prefix(7)) }
        case .rejected, .blocked, .failed: change.event.reason
        default: nil
        }
    }

    private func progressBar(_ progress: ProjectOverview.Progress) -> some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(ProjectOverview.Bucket.allCases, id: \.self) { bucket in
                    let count = progress.count(bucket)
                    if count > 0, progress.total > 0 {
                        Rectangle().fill(Self.tint(bucket))
                            .frame(width: max(2, proxy.size.width * CGFloat(count) / CGFloat(progress.total) - 2))
                    }
                }
            }
        }
        .frame(height: 6)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityHidden(true)
    }

    // MARK: Decisions, changes, evidence

    func decisionsCard(_ decisions: [ProjectOverview.Decision]) -> some View {
        card {
            cardHeader(decisions.isEmpty ? "Pending decisions" : "Pending decisions · \(decisions.count)",
                       trailing: decisions.isEmpty ? nil : String(localized: "for you to settle"))
            if decisions.isEmpty {
                Text("Nothing waits on a decision.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(decisions) { decision in
                nodeButton(id: decision.id) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: decision.title).font(.system(size: 13, weight: .semibold))
                        Text(Self.decisionLine(decision)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                } inspector: {
                    VStack(alignment: .leading, spacing: 0) {
                        inspector(kind: String(localized: "Decision"), id: decision.id, title: decision.title,
                                  status: Self.bucketWord(decision.bucket),
                                  rows: [(String(localized: "Opened"), decision.openedAt.map(Self.shortDate) ?? "—"),
                                         (String(localized: "Review"), decision.sotaGate
                                            ? String(localized: "an agent of another family")
                                            : String(localized: "none — your decision counts"))])
                        inspectorActions(taskID: decision.id, settle: decision.isOpen ? decision : nil)
                    }
                }
            }
        }
    }

    func changesCard(_ changes: [ProjectOverview.Change]) -> some View {
        card {
            sectionTitle("Changes")
            if changes.isEmpty {
                Text("No integration, verdict or block recorded yet.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(changes) { change in
                nodeButton(id: change.id) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: Self.shortDateTime(change.event.timestamp))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(width: 86, alignment: .leading)
                        (Text(Self.eventVerb(change.event.type)).fontWeight(.semibold)
                         + Text(verbatim: " " + change.taskTitle))
                            .font(.system(size: 12.5)).lineLimit(1)
                        Spacer(minLength: 0)
                        if let detail = Self.changeDetail(change) {
                            Text(verbatim: detail).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                } inspector: {
                    inspector(kind: String(localized: "Change"), id: change.taskID, title: change.taskTitle,
                              status: Self.eventVerb(change.event.type),
                              rows: [(String(localized: "When"), Self.shortDateTime(change.event.timestamp)),
                                     (String(localized: "By"), change.event.author),
                                     (String(localized: "Reason"), change.event.reason ?? change.event.note ?? "—")])
                }
            }
        }
    }

    func evidenceCard(_ evidence: ProjectOverview.Evidence) -> some View {
        card {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle(evidence.proofs.isEmpty ? "Evidence" : "Evidence · \(evidence.proofs.count) receipts")
                Spacer()
                Label(evidence.chainValid ? "log chain valid" : "log chain broken",
                      systemImage: evidence.chainValid ? "link" : "link.badge.plus")
                    .font(.system(size: 11)).labelStyle(.titleAndIcon)
                    .foregroundStyle(evidence.chainValid ? Color.green : Color.red)
            }
            if evidence.proofs.isEmpty {
                Text("No verification has run yet.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 14) {
                    Text("\(evidence.count(.passed)) passed")
                    Text("\(evidence.count(.failed)) failed")
                    Text("\(evidence.count(.incomplete)) incomplete")
                }
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(evidence.proofs.prefix(3)) { proof in
                nodeButton(id: "proof:" + proof.id) {
                    HStack(spacing: 8) {
                        Image(systemName: Self.proofSymbol(proof.outcome))
                            .foregroundStyle(Self.proofTint(proof.outcome))
                        Text(verbatim: proof.taskTitle).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(verbatim: Self.testsLine(proof))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                } inspector: {
                    inspector(kind: String(localized: "Evidence"), id: proof.taskID, title: proof.taskTitle,
                              status: Self.proofWord(proof.outcome),
                              rows: [(String(localized: "Expected"), proof.expected.map(String.init) ?? "—"),
                                     (String(localized: "Passed"), proof.passed.map(String.init) ?? "—"),
                                     (String(localized: "Skipped"), proof.skipped.map(String.init) ?? "—"),
                                     (String(localized: "Ran"), Self.shortDateTime(proof.ranAt))])
                }
            }
        }
    }

    // MARK: Costs

    func costsCard(_ costs: ProjectCostReadout) -> some View {
        card {
            sectionTitle("Costs · 4 kinds, never added up")
            costRow(String(localized: "Subscription quota"), note: String(localized: "not measured per project"),
                    figure: costs.subscriptionQuota)
            costRow(String(localized: "API invoice"), note: String(localized: "Throttle does not see your invoice"),
                    figure: costs.apiInvoice)
            costRow(String(localized: "Throttle internal estimate"),
                    note: String(localized: "this month · local calculation, not the invoice"),
                    figure: costs.internalEstimate)
            costRow(String(localized: "Throttle budget reserve"),
                    note: costs.protectedForVerification
                        .map { String(localized: "of which \($0) protected for verification") }
                        ?? String(localized: "no budget ledger for this project"),
                    figure: costs.reserve)
        }
    }

    private func costRow(_ nature: String, note: String, figure: ProjectCostReadout.Figure) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: nature).font(.system(size: 13))
                Text(verbatim: note).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(verbatim: Self.figureValue(figure))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Self.figureIsMeasured(figure) ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            Text(Self.figureKind(figure))
                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
