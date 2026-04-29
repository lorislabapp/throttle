import SwiftUI

/// Per-project Stats tab. Shows tokens (this week / month / all-time),
/// session count, model split, and cost extrapolation — all scoped to
/// one project's events from `usage_events.cwd_path`.
///
/// Free in v2.0: no paywall on this tab. The paywall hits Optimizer +
/// Assistant; Stats and Files are read-only views over data the user
/// already has on disk.
struct ProjectStatsTab: View {
    @Environment(AppState.self) private var appState
    let project: ProjectInfo

    @State private var weekTokens: Int = 0
    @State private var monthTokens: Int = 0
    @State private var sessionCount: Int = 0
    @State private var avgSessionTokens: Int = 0
    @State private var modelSplit: [(label: String, share: Double)] = []
    @State private var costEUR: Double = 0
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if loading {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 32)
                } else {
                    metricsGrid
                    Divider()
                    modelSplitSection
                    Divider()
                    costSection
                }
            }
            .padding(20)
        }
        .onAppear { reload() }
        .onChange(of: project.id) { _, _ in reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.displayName)
                .font(.title2.bold())
            if let path = project.projectPath {
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var metricsGrid: some View {
        HStack(spacing: 12) {
            metricCard(title: String(localized: "This week"),
                       value: formatTokens(weekTokens),
                       subtitle: String(localized: "weighted tokens"))
            metricCard(title: String(localized: "This month"),
                       value: formatTokens(monthTokens),
                       subtitle: String(localized: "weighted tokens"))
            metricCard(title: String(localized: "Sessions"),
                       value: "\(sessionCount)",
                       subtitle: String(localized: "avg \(formatTokens(avgSessionTokens)) / session"))
        }
    }

    private func metricCard(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit())
            Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var modelSplitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model split").font(.headline)
            if modelSplit.isEmpty {
                Text("No model usage yet for this project.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(modelSplit, id: \.label) { slice in
                    HStack {
                        Text(slice.label).font(.callout.bold())
                        Spacer()
                        Text("\(Int(slice.share * 100))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        Rectangle()
                            .fill(.tertiary)
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(width: geo.size.width * slice.share)
                            }
                            .frame(height: 6)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .frame(height: 6)
                }
            }
        }
    }

    private var costSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Estimated API cost").font(.headline)
            Text(formatEUR(costEUR))
                .font(.title3.bold().monospacedDigit())
            Text("What this project would have cost on the developer API at Anthropic's published rates.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Data

    private func reload() {
        loading = true
        let database = appState.database
        let encoded = project.encodedName

        Task {
            struct Bundle: Sendable {
                var week: Int = 0
                var month: Int = 0
                var sessions: Int = 0
                var avgSession: Int = 0
                var split: [(String, Double)] = []
                var cost: Double = 0
            }
            let result: Bundle = await Task.detached {
                var b = Bundle()
                _ = try? database.read { db in
                    b.week = (try? StatsDataService.tokensForProject(in: db, encodedName: encoded, fromHoursAgo: 0, toHoursAgo: 168)) ?? 0
                    b.month = (try? StatsDataService.tokensForProject(in: db, encodedName: encoded, fromHoursAgo: 0, toHoursAgo: 720)) ?? 0
                    let (sessions, avg) = (try? StatsDataService.sessionsForProject(in: db, encodedName: encoded, fromHoursAgo: 0, toHoursAgo: 720)) ?? (0, 0)
                    b.sessions = sessions
                    b.avgSession = avg
                    b.split = (try? StatsDataService.modelSplitForProject(in: db, encodedName: encoded, fromHoursAgo: 0, toHoursAgo: 720)) ?? []
                    b.cost = (try? StatsDataService.costForProject(in: db, encodedName: encoded, fromHoursAgo: 0, toHoursAgo: 720)) ?? 0
                }
                return b
            }.value
            await MainActor.run {
                self.weekTokens = result.week
                self.monthTokens = result.month
                self.sessionCount = result.sessions
                self.avgSessionTokens = result.avgSession
                self.modelSplit = result.split.map { (label: $0.0, share: $0.1) }
                self.costEUR = result.cost
                self.loading = false
            }
        }
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private func formatEUR(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "€0.00"
    }
}
