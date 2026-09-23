import SwiftUI

/// Today's pipeline at a glance: how many tasks sit in each stage that asks
/// something of an agent or of you, across every project. A tile opens the
/// project where that stage has the most recent card.
struct TodayFlowTiles: View {
    let cockpit: MultiCockpitModel
    var projects: CockpitProjectsModel

    private static let stages: [PlanFlow.Stage] = [.working, .fixing, .checking, .ready, .toStart]

    var body: some View {
        let overviews = projects.summaries.compactMap(\.overview)
        if !overviews.isEmpty {
            let totals = PlanFlow.totals(overviews)
            HStack(spacing: 10) {
                ForEach(Self.stages) { stage in
                    tile(stage, count: totals[stage] ?? 0)
                }
            }
        }
    }

    private func tile(_ stage: PlanFlow.Stage, count: Int) -> some View {
        Button {
            if let path = projectPath(for: stage) { cockpit.destination = .project(path: path) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: FlowWording.icon(stage)).foregroundStyle(FlowWording.tint(stage))
                    Text(verbatim: FlowWording.title(stage)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(verbatim: "\(count)").font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(count == 0 ? .secondary : .primary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(count > 0 ? FlowWording.tint(stage).opacity(0.4) : Color.primary.opacity(0.10)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .help(Text(verbatim: FlowWording.explanation(stage)))
    }

    private func projectPath(for stage: PlanFlow.Stage) -> String? {
        projects.summaries
            .compactMap { summary -> (String, Date)? in
                guard let cards = summary.overview.map({ PlanFlow.columns($0) })?
                    .first(where: { $0.stage == stage })?.cards, let first = cards.first else { return nil }
                return (summary.path, first.lastActivity ?? .distantPast)
            }
            .max { $0.1 < $1.1 }?.0
    }
}
