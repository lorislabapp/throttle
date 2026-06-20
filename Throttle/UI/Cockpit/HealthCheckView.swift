import SwiftUI

/// "Throttle Health" panel — runs HealthCheckService and shows a traffic-light
/// list with 1-click fixes where safe. Opened from the cockpit top bar.
struct HealthCheckView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var items: [HealthItem] = []
    @State private var loading = true
    @State private var fixResult: String?

    private let hair = Color.primary.opacity(0.10)

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(hair).frame(height: 1)
            if loading {
                ProgressView("Checking…").controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            row(item)
                            Rectangle().fill(hair).frame(height: 1)
                        }
                    }
                }
            }
            if let fixResult {
                Text(fixResult).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Color.green.opacity(0.08))
            }
        }
        .frame(width: 460, height: 440)
        .onAppear { reload() }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: overallIcon).font(.system(size: 15, weight: .semibold)).foregroundStyle(overallColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Throttle Health").font(.system(size: 13, weight: .semibold))
                Text(overallSummary).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("Re-run checks").disabled(loading)
            Button("Done") { dismiss() }.controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private func row(_ item: HealthItem) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon(item.status)).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color(item.status)).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 12, weight: .medium))
                Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if item.fix != .none {
                Button(fixLabel(item.fix)) { apply(item.fix) }
                    .controlSize(.small).buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    // MARK: - Actions

    private func reload() {
        loading = true; fixResult = nil
        Task {
            let result = await HealthCheckService.run(appState: appState)
            await MainActor.run { self.items = result; self.loading = false }
        }
    }

    private func apply(_ fix: HealthFix) {
        let msg = HealthCheckService.apply(fix)
        fixResult = msg
        reload()
    }

    private func fixLabel(_ fix: HealthFix) -> String {
        switch fix { case .killOrphans: return "Kill"; case .none: return "" }
    }

    // MARK: - Verdict styling

    private func icon(_ s: HealthStatus) -> String {
        switch s { case .ok: return "checkmark.circle.fill"; case .warn: return "exclamationmark.triangle.fill"; case .fail: return "xmark.octagon.fill" }
    }
    private func color(_ s: HealthStatus) -> Color {
        switch s { case .ok: return .green; case .warn: return .orange; case .fail: return .red }
    }

    private var worst: HealthStatus {
        if items.contains(where: { $0.status == .fail }) { return .fail }
        if items.contains(where: { $0.status == .warn }) { return .warn }
        return .ok
    }
    private var overallIcon: String { icon(worst) }
    private var overallColor: Color { color(worst) }
    private var overallSummary: String {
        let fails = items.filter { $0.status == .fail }.count
        let warns = items.filter { $0.status == .warn }.count
        if fails > 0 { return "\(fails) failing · \(warns) warning" }
        if warns > 0 { return "\(warns) warning — otherwise healthy" }
        return loading ? "Running checks…" : "All systems healthy"
    }
}
