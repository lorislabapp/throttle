import SwiftUI
import Charts
import ThrottleShared

/// The standalone value (App Store 4.2): usage history + trends built entirely
/// on-device from accumulated snapshots — works with the Mac OFF.
struct HistoryChartsView: View {
    @State private var store = MirrorStore.shared
    @State private var range: Range = .day

    enum Range: String, CaseIterable, Identifiable {
        case day = "24h", week = "7d", month = "30d"
        var id: String { rawValue }
        var seconds: TimeInterval {
            switch self { case .day: 86_400; case .week: 604_800; case .month: 2_592_000 }
        }
    }

    private var points: [ThrottleMirrorSnapshot] {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        return store.history.filter { $0.publishedAt >= cutoff }
    }

    var body: some View {
        NavigationStack {
            Group {
                if points.count < 2 {
                    ContentUnavailableView("Not enough history yet",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Trends appear as Throttle keeps syncing snapshots."))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            Picker("Range", selection: $range) {
                                ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)

                            chartSection("Binding utilization", unit: "%") { p in
                                Double(p.bindingWindow.utilization)
                            }
                            chartSection("Cost", unit: "€") { $0.weeklyCostEUR }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("History")
        }
    }

    private func chartSection(_ title: String, unit: String,
                              _ value: @escaping (ThrottleMirrorSnapshot) -> Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Chart(points, id: \.publishedAt) { p in
                LineMark(x: .value("Time", p.publishedAt),
                         y: .value(unit, value(p)))
                .foregroundStyle(MirrorUI.accent)
                .interpolationMethod(.monotone)
            }
            .frame(height: 180)
        }
    }
}
