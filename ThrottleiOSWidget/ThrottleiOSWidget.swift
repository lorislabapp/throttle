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
    @Environment(\.widgetFamily) private var family
    var entry: Entry

    private var accent: Color { Color(red: 0.0, green: 0.443, blue: 0.890) }   // #0071E3

    private func color(_ pct: Int) -> Color {
        switch pct {
        case 95...:   Color(red: 1.0, green: 0.231, blue: 0.188)   // #FF3B30
        case 80..<95: Color(red: 1.0, green: 0.624, blue: 0.039)   // #FF9F0A
        default:      accent
        }
    }

    var body: some View {
        switch family {
        case .accessoryCircular:   accessoryCircular
        case .accessoryRectangular: accessoryRectangular
        case .accessoryInline:     accessoryInline
        default:                    home
        }
    }

    // MARK: Home-screen (small / medium)

    @ViewBuilder private var home: some View {
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

    // MARK: Lock-screen accessories

    private var util: Int { entry.snapshot?.bindingWindow.utilization ?? 0 }

    private var accessoryCircular: some View {
        Gauge(value: min(1, Double(util) / 100)) {
            Image(systemName: "gauge.with.needle")
        } currentValueLabel: {
            Text("\(util)").monospacedDigit()
        }
        .gaugeStyle(.accessoryCircular)
        .containerBackground(.clear, for: .widget)
    }

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Claude usage").font(.caption2.weight(.semibold))
            Text("\(util)%").font(.title3.weight(.bold)).monospacedDigit()
            if let snap = entry.snapshot {
                Text("5h \(snap.fiveHour.utilization)% · 7d \(snap.sevenDay.utilization)%")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .containerBackground(.clear, for: .widget)
    }

    private var accessoryInline: some View {
        Label("Claude \(util)%", systemImage: "gauge.with.needle")
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
        .supportedFamilies([.systemSmall, .systemMedium,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Live Activity (lock screen + Dynamic Island)

#if os(iOS)
import ActivityKit

/// Shared colour ramp so the Live Activity matches the widget + the app meter.
private func liveColor(_ pct: Int) -> Color {
    switch pct {
    case 95...:   Color(red: 1.0, green: 0.231, blue: 0.188)   // #FF3B30
    case 80..<95: Color(red: 1.0, green: 0.624, blue: 0.039)   // #FF9F0A
    default:      Color(red: 0.0, green: 0.443, blue: 0.890)   // #0071E3
    }
}

/// Live, self-updating countdown to the window reset — `Text(timerInterval:)` ticks
/// on its own, so the Dynamic Island stays honest between the app's snapshot pushes.
@ViewBuilder private func resetCountdown(_ date: Date?, font: Font) -> some View {
    if let date, date > Date() {
        Text(timerInterval: Date()...date, countsDown: true)
            .font(font).monospacedDigit()
    } else {
        Text("—").font(font)
    }
}

struct ThrottleLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ThrottleActivityAttributes.self) { context in
            // Lock-screen / banner presentation.
            let s = context.state
            HStack(spacing: 14) {
                Gauge(value: min(1, Double(s.binding) / 100)) {
                    Image(systemName: "gauge.with.needle")
                } currentValueLabel: {
                    Text("\(s.binding)").monospacedDigit()
                }
                .gaugeStyle(.accessoryCircular)
                .tint(liveColor(s.binding))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude usage").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text("5h \(s.fiveHour)% · 7d \(s.sevenDay)%").font(.callout.weight(.medium))
                    Text(context.attributes.deviceName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("resets in").font(.caption2).foregroundStyle(.secondary)
                    resetCountdown(s.bindingResetsAt, font: .callout.weight(.semibold))
                        .foregroundStyle(liveColor(s.binding))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .activityBackgroundTint(Color.black.opacity(0.35))
            .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(s.binding)%")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit().foregroundStyle(liveColor(s.binding))
                        Text("used").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("resets in").font(.caption2).foregroundStyle(.secondary)
                        resetCountdown(s.bindingResetsAt, font: .title3.weight(.semibold))
                            .foregroundStyle(liveColor(s.binding))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        miniBar(label: "5h", pct: s.fiveHour)
                        miniBar(label: "7d", pct: s.sevenDay)
                    }
                }
            } compactLeading: {
                Image(systemName: "gauge.with.needle").foregroundStyle(liveColor(s.binding))
            } compactTrailing: {
                Text("\(s.binding)%").monospacedDigit().foregroundStyle(liveColor(s.binding))
            } minimal: {
                Text("\(s.binding)").monospacedDigit().foregroundStyle(liveColor(s.binding))
            }
            .keylineTint(liveColor(s.binding))
        }
    }

    @ViewBuilder private func miniBar(label: String, pct: Int) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
            ProgressView(value: min(1, Double(pct) / 100)).tint(liveColor(pct))
            Text("\(pct)%").font(.caption2).monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
        }
    }
}
#endif

@main
struct ThrottleiOSWidgetBundle: WidgetBundle {
    var body: some Widget {
        ThrottleiOSWidget()
        #if os(iOS)
        ThrottleLiveActivityWidget()
        #endif
    }
}
