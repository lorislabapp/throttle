import WidgetKit
import SwiftUI

/// Compact snapshot decoded from the App Group container. Mirrors the
/// host app's `ThrottleIntentSnapshot` — duplicated here so the widget
/// extension target doesn't pull in the whole app's source tree.
struct WidgetSnapshot: Codable, Sendable {
    let session5hPercent: Double
    let weeklyAllPercent: Double
    let weeklyTokens: Int
    let weeklyCostEUR: Double
    let savedTokensThisWeek: Int
    let computedAt: Date

    static let empty = WidgetSnapshot(
        session5hPercent: 0,
        weeklyAllPercent: 0,
        weeklyTokens: 0,
        weeklyCostEUR: 0,
        savedTokensThisWeek: 0,
        computedAt: .distantPast
    )
}

enum WidgetSnapshotReader {
    static let appGroupID = "group.com.lorislab.throttle"
    static let snapshotKey = "ThrottleIntentSnapshotV1"

    static func read() -> WidgetSnapshot {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: snapshotKey),
              let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else { return .empty }
        return snap
    }
}

struct ThrottleEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct ThrottleProvider: TimelineProvider {
    func placeholder(in context: Context) -> ThrottleEntry {
        ThrottleEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (ThrottleEntry) -> Void) {
        completion(ThrottleEntry(date: Date(), snapshot: WidgetSnapshotReader.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ThrottleEntry>) -> Void) {
        let entry = ThrottleEntry(date: Date(), snapshot: WidgetSnapshotReader.read())
        // The host app refreshes every ~30s when active. Widget timeline
        // refreshes every 5 min — that matches Exact Mode's poll cadence
        // and avoids burning the WidgetKit budget.
        let next = Date().addingTimeInterval(5 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct ThrottleWidgetView: View {
    let entry: ThrottleEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall: smallView
        case .systemMedium: mediumView
        default: smallView
        }
    }

    private var sessionColor: Color {
        let p = entry.snapshot.session5hPercent
        if p >= 95 { return .red }
        if p >= 80 { return .orange }
        return .blue
    }

    private var weeklyColor: Color {
        let p = entry.snapshot.weeklyAllPercent
        if p >= 95 { return .red }
        if p >= 80 { return .orange }
        return .green
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "speedometer")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Throttle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Spacer(minLength: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Int(entry.snapshot.session5hPercent.rounded()))%")
                    .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(sessionColor)
                Text("session 5h")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Int(entry.snapshot.weeklyAllPercent.rounded()))%")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(weeklyColor)
                Text("weekly")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.background, for: .widget)
    }

    private var mediumView: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "speedometer")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Throttle")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
                Text("\(Int(entry.snapshot.session5hPercent.rounded()))%")
                    .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(sessionColor)
                Text("session 5h")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Spacer().frame(height: 14)
                HStack(spacing: 4) {
                    Text("\(Int(entry.snapshot.weeklyAllPercent.rounded()))%")
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(weeklyColor)
                    Text("weekly")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text(formatTokens(entry.snapshot.weeklyTokens))
                        .font(.callout.weight(.semibold).monospacedDigit())
                    Text("tok / 7d")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if entry.snapshot.weeklyCostEUR > 0 {
                    HStack(spacing: 4) {
                        Text(String(format: "€%.0f", entry.snapshot.weeklyCostEUR))
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("@ API rates")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 2)
                // Tap to pause all Claude sessions (opens Throttle, which freezes them).
                Link(destination: URL(string: "throttle://pause")!) {
                    Label("Pause Claude", systemImage: "pause.circle")
                        .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.background, for: .widget)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.0fK",  Double(n) / 1_000) }
        return "\(n)"
    }
}

struct ThrottleWidget: Widget {
    let kind: String = "ThrottleWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ThrottleProvider()) { entry in
            ThrottleWidgetView(entry: entry)
        }
        .configurationDisplayName("Throttle")
        .description("Live Claude Code usage on your desktop.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct ThrottleWidgetBundle: WidgetBundle {
    var body: some Widget {
        ThrottleWidget()
    }
}
