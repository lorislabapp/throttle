import SwiftUI

/// The plan-wide "what now": one sentence and one button above the tree.
extension PlanTreeView {

    @ViewBuilder
    var nextStepBanner: some View {
        if let plan = model.plan {
            let move = PlanOrientation.nextMove(plan: plan, states: model.states)
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: Self.moveIcon(move))
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NEXT STEP").font(.system(size: 9, weight: .semibold)).kerning(0.5)
                        .foregroundStyle(.secondary)
                    Text(verbatim: moveText(move, plan: plan))
                        .font(.system(size: 12, weight: .medium)).lineLimit(2)
                }
                Spacer(minLength: 6)
                moveButton(move)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Color.accentColor.opacity(0.07))
        }
    }

    @ViewBuilder
    func moveButton(_ move: PlanOrientation.NextMove) -> some View {
        switch move {
        case .working(let id, _):
            if let onShowSession {
                Button("Show session") { model.selection = id; onShowSession() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        case .failed(let id), .awaitingReview(let id), .ready(let id), .waiting(let id):
            if model.selection != id {
                Button("Open \(id)") { model.selection = id }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        case .finished:
            EmptyView()
        }
    }

    func moveText(_ move: PlanOrientation.NextMove, plan: Plan) -> String {
        func title(_ id: String) -> String { "\(id) — \(plan.task(id)?.title ?? id)" }
        switch move {
        case .working(let id, let runtime):
            let agent = Self.runtimeName(runtime) ?? String(localized: "An agent")
            return String(localized: "\(agent) is working on \(title(id)). Follow it in its session.")
        case .failed(let id):
            return String(localized: "\(title(id)) failed. Open it to read why, then retry or release it.")
        case .awaitingReview(let id):
            return String(localized: "\(title(id)) is finished and waits for its verification.")
        case .ready(let id):
            return String(localized: "Start \(title(id)): open it, then Launch.")
        case .waiting(let id):
            return String(localized: "Nothing can start yet: \(title(id)) waits on another task.")
        case .finished:
            return String(localized: "Every task in this plan is done.")
        }
    }

    static func moveIcon(_ move: PlanOrientation.NextMove) -> String {
        switch move {
        case .working: "bolt.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .awaitingReview: "checkmark.message"
        case .ready: "play.circle.fill"
        case .waiting: "hourglass"
        case .finished: "checkmark.circle.fill"
        }
    }

    /// "claudeCode" is a storage key; people read "Claude Code".
    static func runtimeName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return AgentRuntime(rawValue: raw)?.label ?? raw
    }
}
