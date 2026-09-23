import SwiftUI

extension PlanTreeView {
    @ViewBuilder
    func designDetails(_ task: PlanTask) -> some View {
        if let design = task.workContract?.design {
            VStack(alignment: .leading, spacing: 7) {
                section("DESIGN CONTRACT")
                fact("Journey", design.goal)
                fact("Entry", design.entryPoint)
                fact("Design tool", designToolLabel(design.designTool))
                ForEach(design.steps) { step in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.action).font(.system(size: 11, weight: .semibold))
                        Text(step.expectedResult).font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(design.states) { state in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(state.kind.rawValue.capitalized)
                            .font(.system(size: 10, weight: .medium))
                        Text(state.behavior ?? state.notApplicableReason ?? "Unspecified")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                Text("Runtime, keyboard, VoiceOver and platform evidence remain separate proofs.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func designToolLabel(_ status: WorkflowDesignToolStatus) -> String {
        switch status.availability {
        case .verified: return String(localized: "\(status.tool) — verified")
        case .unavailable: return String(localized: "\(status.tool) — unavailable")
        }
    }
}
