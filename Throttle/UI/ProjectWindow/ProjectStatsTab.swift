import SwiftUI

/// Per-project Stats tab — the hero of the project window. Cockpit style:
/// a bordered usage grid + a graphite weighted model split, scoped to one
/// project's events. See UI-SPEC-project-window.md. (Per-project daily trend
/// isn't queried yet, so no trend chart here — follow-up.)
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

    private let hair = Color.primary.opacity(0.09)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if loading {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
                } else {
                    usageSection
                    Rectangle().fill(hair).frame(height: 1).padding(.horizontal, 22)
                    modelSplitSection
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: project.id) { _, _ in reload() }
    }

    private func secHeader(_ t: String) -> some View {
        Text(t).font(.system(size: 10.5, weight: .semibold)).tracking(0.8)
            .textCase(.uppercase).foregroundStyle(.tertiary)
    }

    // MARK: - Usage grid

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            secHeader("Usage")
            HStack(spacing: 1) {
                statCell("This week", formatTokens(weekTokens), "weighted")
                statCell("This month", formatTokens(monthTokens), "weighted")
                statCell("Sessions", "\(sessionCount)", "avg \(formatTokens(avgSessionTokens))")
                statCell("API cost", formatEUR(costEUR), "this month")
            }
            .background(hair)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hair, lineWidth: 1))
        }
        .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 16)
    }

    private func statCell(_ k: String, _ v: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(k).font(.system(size: 10, weight: .semibold)).tracking(0.5)
                .textCase(.uppercase).foregroundStyle(.tertiary)
            Text(v).font(.system(size: 21).monospacedDigit())
            Text(sub).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Model split

    private func splitOpacity(_ i: Int) -> Double {
        switch i { case 0: return 0.72; case 1: return 0.42; case 2: return 0.20; default: return 0.12 }
    }

    @ViewBuilder
    private var modelSplitSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            secHeader("Model split · weighted")
            if modelSplit.isEmpty {
                Text("No model usage yet for this project.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(Array(modelSplit.enumerated()), id: \.element.label) { i, slice in
                            Color.primary.opacity(splitOpacity(i))
                                .frame(width: max(0, geo.size.width * slice.share))
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: 9)
                .background(Color.primary.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 5))

                VStack(spacing: 7) {
                    ForEach(Array(modelSplit.enumerated()), id: \.element.label) { i, slice in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(splitOpacity(i)))
                                .frame(width: 8, height: 8)
                            Text(slice.label).font(.system(size: 11.5))
                            Spacer(minLength: 0)
                            Text("\(Int(slice.share * 100))%").font(.system(size: 11.5).monospacedDigit())
                        }
                    }
                }
                .padding(.top, 2)

                HStack {
                    Text("API-equivalent / mo").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(formatEUR(costEUR)).font(.system(size: 13).monospacedDigit())
                }
                .padding(.top, 9)
                .overlay(alignment: .top) { Rectangle().fill(hair).frame(height: 1) }
            }
        }
        .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 18)
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
        formatter.maximumFractionDigits = value >= 100 ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? "€0"
    }
}
