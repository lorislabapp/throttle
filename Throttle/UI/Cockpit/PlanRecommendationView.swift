import SwiftUI

// The recommendation block and the launch it triggers, kept out of the tree view
// so the part that spends the user's money reads on its own.
extension PlanTreeView {

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
                    Text("every runtime is out of window until "
                         + wait.formatted(date: .omitted, time: .shortened))
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
                Text(String(format: "≈%.0f× the tokens of a single agent", multiplier))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                if let runtime = advice.runtime {
                    Button("Launch") { launch(taskID: taskID, runtime: runtime) }
                        .controlSize(.small)
                }
                Menu(advice.runtime == nil ? "Choose…" : "Change…") {
                    ForEach([AgentRuntime.claudeCode, .codex]) { runtime in
                        Button(runtime.label) { launch(taskID: taskID, runtime: runtime) }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
            }
            .padding(.top, 2)

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
        } catch let error as TaskLauncher.LaunchError {
            switch error {
            case .alreadyHeld(_, let owner): launchError = "Taken by \(owner) a moment ago."
            case .unknownTask(let id): launchError = "No task \(id) in this plan."
            }
        } catch {
            launchError = String(describing: error)
        }
    }

}
