import AppKit
import SwiftUI

// The one button a card's "what to do now" needs when the next step is not an
// agent launch: starting the independent review, or opening the plan to declare
// a missing check. Without it the card names a step and leaves the user to guess.
extension PlanTreeView {

    @ViewBuilder
    func nextActionButton(_ task: PlanTask, _ state: TaskState) -> some View {
        switch state.status {
        case .review:
            let reviewer = TaskReviewLauncher.reviewer(for: state.runtime)
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    launchReview(taskID: task.id, runtime: reviewer)
                } label: {
                    Label("Launch review with \(reviewer.label)", systemImage: reviewer.symbol)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .help(Text(
                    "Opens a \(reviewer.label) session that may only read the plan and record one verdict on this task."
                ))
                if let launchError {
                    Text(launchError).font(.system(size: 11)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .candidate where model.declaredVerifyCommand(for: task.id) == nil:
            if let url = model.planFileURL {
                Button("Open plan.json") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        default:
            EmptyView()
        }
    }

    func launchReview(taskID: String, runtime: AgentRuntime) {
        do {
            launchError = nil
            onLaunch?(try model.prepareReview(taskID: taskID, runtime: runtime))
        } catch let error as TaskReviewLauncher.ReviewError {
            switch error {
            case .unknownTask(let id):
                launchError = String(localized: "No task \(id) in this plan.")
            case .notAwaitingReview(let id, let status):
                launchError = String(localized: "\(id) is \(status) now, not awaiting review.")
            case .sameRuntime(let name):
                launchError = String(localized: "\(name) did this work and cannot judge it.")
            }
        } catch {
            launchError = String(describing: error)
        }
    }
}
