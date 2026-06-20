import SwiftUI

/// "Work activity" — cross-project view of how much real time you spend in Claude
/// Code: active hours today + this week, projects and sessions touched this week,
/// a 7-day bar chart, and your top projects by time. "Active" uses the same
/// idle-aware block rule as per-project time, so it's honest time-at-keyboard.
struct WorkActivityView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var data = StatsDataService.WorkActivity()
    @State private var loading = true

    private let hair = Color.primary.opacity(0.10)

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(hair).frame(height: 1)
            if loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        topStats
                        chartSection
                        if !data.topProjects.isEmpty { topProjectsSection }
                    }
                    .padding(18)
                }
            }
        }
        .frame(width: 460, height: 520)
        .onAppear { reload() }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Work activity").font(.system(size: 13, weight: .semibold))
                Text("Active time across all Claude Code projects").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("Refresh").disabled(loading)
            Button("Done") { dismiss() }.controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private var topStats: some View {
        HStack(spacing: 1) {
            cell("Today", hm(data.activeToday), "active")
            cell("This week", hm(data.activeWeek), "active")
            cell("Projects", "\(data.projectsThisWeek)", "this week")
            cell("Sessions", "\(data.sessionsThisWeek)", "this week")
        }
        .background(hair).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hair, lineWidth: 1))
    }

    private func cell(_ k: String, _ v: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(k.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.5).foregroundStyle(.tertiary)
            Text(v).font(.system(size: 20).monospacedDigit())
            Text(sub).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LAST 7 DAYS").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(.tertiary)
            let maxSecs = max(data.daily.map(\.seconds).max() ?? 1, 1)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(data.daily.enumerated()), id: \.offset) { _, d in
                    VStack(spacing: 5) {
                        Text(d.seconds >= 60 ? hmShort(d.seconds) : "").font(.system(size: 8.5).monospacedDigit()).foregroundStyle(.tertiary)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(0.55))
                            .frame(height: max(2, 92 * d.seconds / maxSecs))
                        Text(weekday(d.day)).font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 128, alignment: .bottom)
        }
    }

    private var topProjectsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TOP PROJECTS · THIS WEEK").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(.tertiary)
            let maxSecs = max(data.topProjects.map(\.seconds).max() ?? 1, 1)
            ForEach(Array(data.topProjects.enumerated()), id: \.offset) { _, p in
                HStack(spacing: 10) {
                    Text(p.name).font(.system(size: 11.5)).lineLimit(1).frame(width: 130, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(hair)
                            Capsule().fill(Color.accentColor.opacity(0.45))
                                .frame(width: max(3, geo.size.width * p.seconds / maxSecs))
                        }
                    }.frame(height: 7)
                    Text(hm(p.seconds)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                }
            }
        }
    }

    private func reload() {
        loading = true
        let database = appState.database
        Task {
            let result = await Task.detached(priority: .utility) {
                (try? database.read { try StatsDataService.workActivity(in: $0) }) ?? StatsDataService.WorkActivity()
            }.value
            await MainActor.run { self.data = result; self.loading = false }
        }
    }

    // MARK: - Format

    private func hm(_ s: TimeInterval) -> String {
        let m = Int(s) / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60, rm = m % 60
        return rm == 0 ? "\(h)h" : "\(h)h\(rm)m"
    }
    private func hmShort(_ s: TimeInterval) -> String {
        let m = Int(s) / 60
        return m < 60 ? "\(m)m" : String(format: "%.1fh", Double(m) / 60)
    }
    private func weekday(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f.string(from: d)
    }
}
