import SwiftUI

/// Traycer readout — **€ per skill**, measure-only, per project. Joins the OTel
/// event stream (`traycer_events`, captured by the local `TraycerReceiver`) to
/// token/cost in `usage_events` by session, attributing each session's cost to
/// the skill that owned the time window. No interception, no rewrite — a pure
/// read of a local join. Hidden until at least one skill has attributed cost, so
/// it stays invisible for users who never opted the telemetry export in.
struct TraycerReadout: View {
    let project: ProjectInfo

    @Environment(AppState.self) private var appState
    @State private var costs: [StatsDataService.SkillCost] = []
    private var hair: Color { Color.primary.opacity(0.09) }

    var body: some View {
        Group {
            if !costs.isEmpty {
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("SKILL COST")
                            .font(.system(size: 9.5, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(.tertiary)
                        Text("measure-only · last 14d · € attributed by session")
                            .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        Spacer(minLength: 8)
                    }
                    VStack(spacing: 5) {
                        ForEach(costs.prefix(6), id: \.skill) { c in
                            HStack(spacing: 10) {
                                Text(c.skill)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text("×\(c.fires)")
                                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                Text(String(format: "€%.2f", c.eur))
                                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 52, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Rectangle().fill(hair).frame(height: 1)
            }
        }
        .task(id: project.encodedName) {
            let enc = project.encodedName
            let db = appState.database
            costs = await Task.detached(priority: .utility) {
                (try? db.read { try StatsDataService.traycerSkillCosts(in: $0, project: enc) }) ?? []
            }.value
        }
    }
}
