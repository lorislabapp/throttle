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

                            chartSection("Binding utilization", unit: "%",
                                         tint: MirrorUI.accent, filled: true) { p in
                                Double(p.bindingWindow.utilization)
                            }
                            chartSection("Cost", unit: "€", tint: MirrorUI.ok) { $0.weeklyCostEUR }
                            chartSection("Tokens saved", unit: "",
                                         tint: MirrorUI.warn) { Double($0.savedTokensThisWeek) }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("History")
        }
    }

    private func chartSection(_ title: String, unit: String, tint: Color,
                              filled: Bool = false,
                              _ value: @escaping (ThrottleMirrorSnapshot) -> Double) -> some View {
        let vals = points.map(value)
        let peak = vals.max() ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text(unit.isEmpty ? MirrorUI.compactTokens(Int(peak))
                                  : "\(unit)\(String(format: "%.0f", peak)) peak")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Chart(points, id: \.publishedAt) { p in
                if filled {
                    AreaMark(x: .value("Time", p.publishedAt), y: .value(unit, value(p)))
                        .foregroundStyle(.linearGradient(
                            colors: [tint.opacity(0.28), tint.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                }
                LineMark(x: .value("Time", p.publishedAt), y: .value(unit, value(p)))
                    .foregroundStyle(tint)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartXAxis {
                AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) {
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) {
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                    AxisValueLabel()
                }
            }
            .frame(height: 170)
        }
    }
}
