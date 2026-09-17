import SwiftUI
import TipKit

// The recommendation block and the launch it triggers, kept out of the tree view
// so the part that spends the user's money reads on its own.
extension PlanTreeView {

    @ViewBuilder
    func budgetFacts(_ state: TaskState) -> some View {
        if let reservation = state.budgetReservationID {
            fact("Budget hold", reservation.uuidString)
            fact("Enforcement", String(localized: "local admission only"))
        }
    }

    @ViewBuilder
    func reviewDetails(_ state: TaskState) -> some View {
        if let report = state.lastReview {
            VStack(alignment: .leading, spacing: 7) {
                section("INDEPENDENT REVIEW")
                fact("Reviewer", report.reviewerID)
                fact("Candidate", report.candidateStamp)
                if let digest = report.digest {
                    fact("Report", String(digest.prefix(12)))
                }
                ForEach(report.assessments) { assessment in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: reviewSymbol(assessment.outcome))
                                .foregroundStyle(reviewColor(assessment.outcome))
                            Text(reviewCriterionLabel(assessment.criterionID))
                                .font(.system(size: 11, weight: .semibold))
                            Spacer(minLength: 4)
                            Text(reviewOutcomeLabel(assessment.outcome))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(reviewColor(assessment.outcome))
                        }
                        if let note = assessment.note {
                            Text(note).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let reason = assessment.notApplicableReason {
                            Text(reason).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(assessment.evidence, id: \.self) { evidence in
                            Text("\(evidence.kind)  \(evidence.ref)")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    private func reviewCriterionLabel(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: " ")
    }

    private func reviewOutcomeLabel(_ outcome: WorkflowReviewOutcome) -> String {
        switch outcome {
        case .pass: return String(localized: "PASS")
        case .fail: return String(localized: "FAIL")
        case .notVerified: return String(localized: "NOT VERIFIED")
        case .notApplicable: return String(localized: "N/A")
        }
    }

    private func reviewSymbol(_ outcome: WorkflowReviewOutcome) -> String {
        switch outcome {
        case .pass: return "checkmark.circle.fill"
        case .fail: return "xmark.octagon.fill"
        case .notVerified: return "questionmark.circle.fill"
        case .notApplicable: return "minus.circle.fill"
        }
    }

    private func reviewColor(_ outcome: WorkflowReviewOutcome) -> Color {
        switch outcome {
        case .pass: return .green
        case .fail: return .red
        case .notVerified: return .orange
        case .notApplicable: return .secondary
        }
    }

    @ViewBuilder
    func recommendation(_ advice: DispatchAdvice, taskID: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            section("RECOMMENDATION")

            switch advice.verdict {
            case .runtime(let runtime):
                HStack(spacing: 6) {
                    Image(systemName: runtime.symbol).font(.system(size: 11))
                    Text(runtime.label).font(.system(size: 12, weight: .semibold))
                    Text(advice.confidence.rawValue)
                        .font(.system(size: 9, weight: .medium)).kerning(0.4)
                        .foregroundStyle(.secondary)
                }
            case .abstain:
                // Saying "I don't know" plainly is the product behaviour, not a
                // failure state — so it reads as a considered answer.
                Text("No clear choice — pick one")
                    .font(.system(size: 12, weight: .semibold))
                if let wait = advice.waitUntil {
                    Text("Every runtime is out of window until \(wait.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            ForEach(Array(advice.reasons.enumerated()), id: \.offset) { _, reason in
                Text("· \(reason)").font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The multiplier is the number that costs money, so it is stated
            // before the button, not hidden behind it.
            if let multiplier = advice.tokenMultiplier {
                Text(String.localizedStringWithFormat(
                    String(localized: "≈%@× the tokens of a single agent"),
                    multiplier.formatted(.number.precision(.fractionLength(0)))
                ))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                if let runtime = advice.runtime {
                    Button("Launch") { launch(taskID: taskID, runtime: runtime) }
                        .controlSize(.small)
                }
                Menu(advice.runtime == nil
                     ? String(localized: "Choose…")
                     : String(localized: "Change…")) {
                    ForEach([AgentRuntime.claudeCode, .codex]) { runtime in
                        Button(runtime.label) { launch(taskID: taskID, runtime: runtime) }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
            }
            .padding(.top, 2).popoverTip(LaunchTaskTip(), arrowEdge: .top)

            if let launchError {
                Text(launchError).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func launch(taskID: String, runtime: AgentRuntime) {
        do {
            launchError = nil
            onLaunch?(try model.prepareLaunch(taskID: taskID, runtime: runtime))
            CockpitOnboarding.markDone(.launchTask)
        } catch let error as TaskLauncher.LaunchError {
            switch error {
            case .alreadyHeld(_, let owner):
                launchError = String(localized: "Taken by \(owner) a moment ago.")
            case .unknownTask(let id):
                launchError = String(localized: "No task \(id) in this plan.")
            case .budget(let reason):
                launchError = String(localized: "Budget refused: \(String(describing: reason))")
            }
        } catch {
            launchError = String(describing: error)
        }
    }

}
