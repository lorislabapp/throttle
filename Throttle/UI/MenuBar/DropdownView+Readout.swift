import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

extension DropdownView {
    var titleRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 15))
                .foregroundStyle(.primary.opacity(0.9))
            Text("Throttle").font(.system(size: 14.5, weight: .semibold))
            Spacer(minLength: 0)
            if appState.isPro { pillSoft("PRO") } else { pillFree("FREE") }
            if appState.exactSnapshot?.isFresh() == true {
                HStack(spacing: 4) {
                    Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 4, height: 4)
                    Text("EXACT")
                }
                .font(.system(size: 9.5, weight: .heavy))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.primary, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 13).padding(.bottom, 12)
    }

    func pillSoft(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 9.5, weight: .heavy))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(.secondary)
    }

    func pillFree(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 9.5, weight: .heavy))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .foregroundStyle(.tertiary)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.12), lineWidth: 1))
    }

    func emptyState(message: String) -> some View {
        VStack {
            Image(systemName: "gauge.with.dots.needle.0percent")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    var hairColor: Color { Color.primary.opacity(0.09) }
    var hairline: some View {
        Rectangle().fill(hairColor).frame(height: 1).padding(.horizontal, 16)
    }
    var secKick: some View {
        Text("OTHER WINDOWS")
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .padding(.top, 11).padding(.bottom, 3)
    }

    /// Binding hero + "Other windows" rows. The binding window — closest to its
    /// cap — owns the big readout; the rest recede. Emphasis follows risk: the
    /// hero swaps to whichever window is highest. Confidence still outranks size.
    @ViewBuilder
    var meterReadout: some View {
        let metrics = [
            displayMetric(for: .session5h),
            displayMetric(for: .weeklyAll),
            displayMetric(for: .weeklySonnet)
        ]
        // The hero obeys the same rule as the menu bar and the statusline: the
        // per-model weekly cap is shown as a ROW, never promoted to the headline.
        // Exhausting it forces a model fallback; it does not stop you. This was
        // the one surface `UsagePressure` did not reach, so the popover could
        // announce "Binding now · Weekly · Fable — 100%" in red while the menu
        // bar one click away read 62%.
        let binding = metrics
            .filter { $0.percent != nil && $0.kind != .weeklySonnet }
            .max { ($0.percent ?? 0) < ($1.percent ?? 0) }
            ?? metrics.filter { $0.percent != nil }.max { ($0.percent ?? 0) < ($1.percent ?? 0) }
        if let binding {
            bindingHero(binding)
            hairline
            secKick
            rows(metrics.filter { $0.kind != binding.kind })
        } else {
            // Nothing calibrated yet — all windows as calibrate rows, no hero.
            rows(metrics).padding(.top, 4)
        }
    }

    @ViewBuilder
    func rows(_ metrics: [DisplayMetric]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { idx, m in
                if idx > 0 { Rectangle().fill(hairColor).frame(height: 1) }
                secondaryRow(m)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    struct DisplayMetric: Identifiable {
        let kind: WindowKind
        let title: String         // "Session", "Weekly"
        let subtitle: String      // "5-hour", "all models", "Sonnet only"
        let bindingLabel: String  // "Session (5h)", "Weekly · Sonnet only"
        let percent: Double?
        let resetInSeconds: Int64
        let isExact: Bool
        var id: WindowKind { kind }
    }

    func displayMetric(for kind: WindowKind) -> DisplayMetric {
        let title: String, subtitle: String, bindingLabel: String
        switch kind {
        case .session5h:
            title = String(localized: "Session")
            subtitle = String(localized: "5-hour")
            bindingLabel = String(localized: "Session (5h)")
        case .weeklyAll:
            title = String(localized: "Weekly")
            subtitle = String(localized: "all models")
            bindingLabel = String(localized: "Weekly · all models")
        case .weeklySonnet:
            // Named after the model the server scoped the cap to. This row read
            // "Sonnet only" unconditionally while the cap at 100% was Fable's.
            title = String(localized: "Weekly")
            subtitle = ScopedCapModel.subtitle
            bindingLabel = ScopedCapModel.bindingLabel
        }
        let local: UsageSnapshot.Window
        switch kind {
        case .session5h:    local = appState.snapshot.session5h
        case .weeklyAll:    local = appState.snapshot.weeklyAll
        case .weeklySonnet: local = appState.snapshot.weeklySonnet
        }
        if let exact = appState.exactSnapshot, exact.isFresh() {
            let ew: ExactSnapshot.Window
            switch kind {
            case .session5h:    ew = exact.fiveHour
            case .weeklyAll:    ew = exact.sevenDay
            case .weeklySonnet: ew = exact.sevenDaySonnet
            }
            let resetSec: Int64 = ew.resetsAt.map {
                max(0, Int64($0.timeIntervalSinceNow))
            } ?? local.resetInSeconds
            return DisplayMetric(
                kind: kind, title: title, subtitle: subtitle, bindingLabel: bindingLabel,
                percent: Double(ew.utilization) / 100.0,
                resetInSeconds: resetSec, isExact: true
            )
        }
        return DisplayMetric(
            kind: kind, title: title, subtitle: subtitle, bindingLabel: bindingLabel,
            percent: local.percentUsed,
            resetInSeconds: local.resetInSeconds, isExact: false
        )
    }

    /// The binding window as the hero: 56pt number, headroom, a bar with labelled
    /// 80/95 danger ticks, reset + "closest to cap". When degraded (exact on but
    /// falling back to local math), the hero ITSELF wears the ≈/estimate treatment
    /// — confidence outranks size, so a local 90% never reads as server-true.
    @ViewBuilder
    func bindingHero(_ m: DisplayMetric) -> some View {
        let pct = m.percent ?? 0
        let deg = degraded(m)
        let tint = progressTint(for: pct)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text("Binding now")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(verbatim: "·").foregroundStyle(.tertiary)
                Text(m.bindingLabel)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary)
                if deg { estimateTag }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 7)

            HStack(alignment: .bottom, spacing: 13) {
                HStack(alignment: .lastTextBaseline, spacing: 0) {
                    if deg {
                        Text(verbatim: "≈")
                            .font(.system(size: 34, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Text("\(Int(pct * 100))")
                        .font(.system(size: 56, weight: .semibold).monospacedDigit())
                        .tracking(-1.5)
                        .foregroundStyle(numberColor(pct: pct, degraded: deg))
                    Text(verbatim: "%")
                        .font(.system(size: 22, weight: .medium)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("used").font(.system(size: 11)).foregroundStyle(.secondary)
                    (Text("\(deg ? "≈" : "")\(max(0, 100 - Int(pct * 100)))%").foregroundStyle(.primary)
                     + Text(" headroom left").foregroundStyle(.secondary))
                        .font(.system(size: 11))
                }
                .padding(.bottom, 8)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 14)

            UsageBar(pct: pct, tint: tint, degraded: deg, height: 9, strongTicks: true)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    Text(verbatim: "80")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                        .offset(x: w * 0.80 - 6)
                    Text(verbatim: "95")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                        .offset(x: w * 0.95 - 6)
                }
            }
            .frame(height: 12)
            .padding(.top, 4)

            HStack {
                if m.resetInSeconds > 0 {
                    (Text("resets ").foregroundStyle(.tertiary)
                     + Text(formatWallClock(m.resetInSeconds)).foregroundStyle(.secondary)
                     + Text(" (in \(MultiCockpitModel.countdown(m.resetInSeconds)))").foregroundStyle(.tertiary))
                        .font(.system(size: 11))
                }
                Spacer(minLength: 0)
                Text("closest to cap").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 15).padding(.bottom, 16)
    }

    /// A non-binding window: full row — label + bar + reset underneath. Same
    /// confidence treatment as the hero. Not-calibrated → "—%" + a tappable
    /// "tap to set your cap›" status line.
    @ViewBuilder
    func secondaryRow(_ m: DisplayMetric) -> some View {
        let deg = degraded(m)
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(m.title).font(.system(size: 12.5, weight: .semibold))
                Text(m.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let pct = m.percent {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        if deg {
                            Text(verbatim: "≈").font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Text("\(Int(pct * 100))")
                            .font(.system(size: 18, weight: .medium).monospacedDigit())
                            .foregroundStyle(numberColor(pct: pct, degraded: deg))
                        Text(verbatim: "%").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(verbatim: "—%").font(.system(size: 16)).foregroundStyle(.tertiary)
                }
            }
            if let pct = m.percent {
                UsageBar(pct: pct, tint: progressTint(for: pct), degraded: deg, height: 6)
                HStack {
                    if m.resetInSeconds > 0 {
                        (Text("resets ") + Text(formatWallClock(m.resetInSeconds))
                         + Text(" (in \(MultiCockpitModel.countdown(m.resetInSeconds)))").foregroundStyle(.tertiary))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if deg { estimateTag }
                }
            } else {
                UsageBar(pct: nil, tint: progressTint(for: 0), height: 6)
                (Text("Not calibrated yet — ").foregroundStyle(.secondary)
                 + Text("tap to set your cap›").foregroundStyle(.tint))
                    .font(.system(size: 11))
                    .onTapGesture { mode = .settings(.calibration) }
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    var estimateTag: some View {
        Text("estimate")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.12), lineWidth: 1))
    }

    /// Track + leading-anchored fill. Pressure earns colour via `tint` (neutral
    /// graphite until 80% → orange → red). Faint threshold ticks at 80/95 mark
    /// where it starts (stronger under the hero). Degraded (estimate) fill is a
    /// diagonal hatch in the tint colour — no Canvas (macOS 26.5 Metal
    /// regression), the stripes are a stroked Path.
}
