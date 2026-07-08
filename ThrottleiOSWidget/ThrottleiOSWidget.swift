import WidgetKit
import SwiftUI
import ThrottleShared

/// Reads the latest mirror snapshot the iOS app wrote to the App Group.
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), snapshot: MirrorSnapshotReader.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entry = Entry(date: Date(), snapshot: MirrorSnapshotReader.read())
        // The app calls WidgetCenter.reloadAllTimelines() on each push; a 15-min
        // safety refresh keeps the cap countdown honest if pushes are throttled.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: ThrottleMirrorSnapshot?
    static let sample = Entry(date: Date(), snapshot: nil)
}

enum MirrorSnapshotReader {
    static func read() -> ThrottleMirrorSnapshot? {
        let defaults = UserDefaults(suiteName: MirrorStorage.appGroupID)
        guard let data = defaults?.data(forKey: MirrorStorage.latestSnapshotKey) else { return nil }
        return try? ThrottleMirrorSnapshot.decoded(from: data)
    }
}

struct ThrottleiOSWidgetEntryView: View {
    var entry: Entry

    private var accent: Color { Color(red: 0.0, green: 0.443, blue: 0.890) }

    private func color(_ pct: Int) -> Color {
        switch pct { case 95...: .red; case 80..<95: .orange; default: accent }
    }

    var body: some View {
        if let snap = entry.snapshot {
            let w = snap.bindingWindow
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Throttle").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "gauge.with.needle").font(.caption2).foregroundStyle(accent)
                }
                Spacer()
                Text("\(w.utilization)%")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color(w.utilization))
                ProgressView(value: min(1, Double(w.utilization) / 100))
                    .tint(color(w.utilization))
                Text("5h \(snap.fiveHour.utilization)% · 7d \(snap.sevenDay.utilization)%")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
                Text("No data").font(.caption).foregroundStyle(.secondary)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
    }
}

struct ThrottleiOSWidget: Widget {
    let kind = "ThrottleiOSWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            ThrottleiOSWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Claude Usage")
        .description("Your Claude Code 5-hour and 7-day usage at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct ThrottleiOSWidgetBundle: WidgetBundle {
    var body: some Widget { ThrottleiOSWidget() }
}
