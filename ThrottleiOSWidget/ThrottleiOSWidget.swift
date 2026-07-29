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

/// Colour ramp shared with the widget + app meter. #0071E3 normal, amber, red.
private func liveColor(_ pct: Int) -> Color {
    switch pct {
    case 95...:   Color(red: 1.0, green: 0.231, blue: 0.188)   // #FF3B30
    case 80..<95: Color(red: 1.0, green: 0.624, blue: 0.039)   // #FF9F0A
    default:      Color(red: 0.0, green: 0.443, blue: 0.890)   // #0071E3
    }
}

/// Non-colour urgency cue (LA-M01): the "about to be capped" state must survive
/// colour-blind vision and the monochrome minimal presentation, so swap the glyph
/// at the critical threshold rather than relying on hue alone.
private func liveGlyph(_ pct: Int) -> String {
    pct >= 95 ? "exclamationmark.triangle.fill" : "gauge.with.needle"
}

/// Countdown to the window reset. A live `Text(timerInterval:)` is a stopwatch with
/// no day field, so a multi-day reset (the 7-day window binding) renders as
/// "71:24:07" under a "resets in" label — semantically wrong and too wide to fit.
/// Tick live only under 6h, where the second-by-second count earns its place; above
/// that show a coarse relative string ("in 3 days"). (LA-H01)
@ViewBuilder private func resetCountdown(_ date: Date?, font: Font) -> some View {
    if let date, date > Date() {
        if date.timeIntervalSinceNow > 6 * 3600 {
            Text(date, format: .relative(presentation: .named))
                .font(font).lineLimit(1).minimumScaleFactor(0.8)
        } else {
            Text(timerInterval: Date()...date, countsDown: true)
                .font(font).monospacedDigit().lineLimit(1)
                .accessibilityHidden(true)   // ticking text spams VoiceOver; reset is in the combined label
        }
    } else {
        Text("—").font(font)
    }
}

/// One glanceable spoken label for the whole banner (LA-H03) — otherwise VoiceOver
/// reads ~6 disjoint fragments, one of which (the live timer) keeps re-firing.
private func a11yLabel(_ s: ThrottleActivityAttributes.ContentState) -> String {
    "Claude usage \(s.binding) percent. 5-hour \(s.fiveHour) percent, 7-day \(s.sevenDay) percent."
}

struct ThrottleLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ThrottleActivityAttributes.self) { context in
            // Lock-screen / banner presentation.
            let s = context.state
            HStack(spacing: 14) {
                Gauge(value: min(1, Double(s.binding) / 100)) {
                    Image(systemName: liveGlyph(s.binding))
                } currentValueLabel: {
                    Text("\(s.binding)").monospacedDigit().minimumScaleFactor(0.7)
                }
                .gaugeStyle(.accessoryCircular)
                .tint(liveColor(s.binding))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude usage").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                    Text("5h \(s.fiveHour)% · 7d \(s.sevenDay)%").font(.callout.weight(.medium))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(context.attributes.deviceName).font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("resets in").font(.caption2).foregroundStyle(.white.opacity(0.7))
                    resetCountdown(s.bindingResetsAt, font: .callout.weight(.semibold))
                        .foregroundStyle(liveColor(s.binding))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            // Near-opaque tint so wallpaper doesn't bleed under the text and drop it
            // below AA contrast (LA-H02).
            .activityBackgroundTint(Color(white: 0.09).opacity(0.92))
            .activitySystemActionForegroundColor(.white)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(a11yLabel(s))

        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(s.binding)%")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit().minimumScaleFactor(0.6).foregroundStyle(liveColor(s.binding))
                        Text("used").font(.caption2).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(s.binding) percent used")
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
                Image(systemName: liveGlyph(s.binding)).foregroundStyle(liveColor(s.binding))
                    .accessibilityLabel("Claude usage \(s.binding) percent")
            } compactTrailing: {
                Text("\(s.binding)%").monospacedDigit().minimumScaleFactor(0.7).foregroundStyle(liveColor(s.binding))
            } minimal: {
                Text("\(s.binding)").monospacedDigit().minimumScaleFactor(0.7).foregroundStyle(liveColor(s.binding))
                    .accessibilityLabel("Claude usage \(s.binding) percent")
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label == "5h" ? "5 hour" : "7 day") \(pct) percent")
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
