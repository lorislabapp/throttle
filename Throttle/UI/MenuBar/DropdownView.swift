import AppKit
import GRDB
import SwiftUI

struct DropdownView: View {
    @Environment(AppState.self) private var appState

    enum Mode {
        case meter
        case settings(SettingsTab)
        case stats
        case projects
    }

    enum SettingsTab: String, CaseIterable {
        case general
        case pro
        case assistant
        case calibration
        case hooks
        case about

        /// Terse label for the console tab bar (six must fit at 440pt).
        var tabLabel: String {
            switch self {
            case .general:     return String(localized: "General")
            case .pro:         return String(localized: "Pro")
            case .assistant:   return String(localized: "AI")
            case .calibration: return String(localized: "Caps")
            case .hooks:       return String(localized: "Hooks")
            case .about:       return String(localized: "About")
            }
        }
    }

    @State private var mode: Mode = .meter
    @State private var embeddedSignedIn: Bool = false

    var body: some View {
        Group {
            if !appState.firstRunDone {
                FirstRunInline()
            } else {
                switch mode {
                case .meter:
                    meterContent
                case .settings(let tab):
                    settingsContent(tab: tab)
                case .stats:
                    StatsInline(onBack: { mode = .meter })
                case .projects:
                    ProjectWindowRoot(onBack: { mode = .meter })
                }
            }
        }
        .padding(meterEdgeToEdge ? 0 : 12)
        .frame(width: dropdownWidth, height: dropdownHeight)
    }

    /// The meter and Stats are native sectioned lists — full-bleed hairline
    /// separators with 16pt internal section padding. Other modes keep the 12pt inset.
    private var meterEdgeToEdge: Bool {
        guard appState.firstRunDone else { return true }  // onboarding is edge-to-edge
        switch mode {
        case .meter, .stats, .settings: return true
        default:                        return false
        }
    }

    /// Dropdown grows to a "real window" footprint in projects mode.
    /// MenuBarExtra `.window` style lets the popover size be driven by
    /// the SwiftUI content's frame, so we adjust width + height per mode.
    private var dropdownWidth: CGFloat {
        if case .projects = mode { return 860 }
        return 440
    }
    private var dropdownHeight: CGFloat? {
        if case .projects = mode { return 540 }
        return nil
    }

    // MARK: - Meter mode

    private var meterContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            hairline
            exactModeWarningBanner.padding(.horizontal, 16)
            if !appState.claudeCodeDetected {
                emptyState(message: "Claude Code not detected. Install it to start measuring.")
            } else if !appState.snapshot.hasAnyData {
                emptyState(message: "No sessions yet — start one in Claude Code.")
            } else {
                meterReadout
            }
            if !appState.isPro && appState.snapshot.hasAnyData {
                ProUpsellBanner(configSize: 95, savings: 40)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            if appState.savedTokensThisWeek > 0 {
                hairline
                savingsFootnote
            }
            hairline
            dockFooter
        }
        .onAppear {
            // Keep milestone accrual + the footer's signed-in label working.
            _ = MilestoneTracker.shared.observeWeeklySnapshot(appState.savedTokensThisWeek)
            Task { @MainActor in
                embeddedSignedIn = await EmbeddedClaudeSession.shared.isSignedIn()
            }
        }
    }

    /// Quiet one-line savings summary. Demoted from the old green hero card:
    /// savings answers "did this pay for itself", not "should I stop now" —
    /// so it sits as a footnote under the actions, never competing with the
    /// usage meter, which is the reason you open Throttle. The milestone
    /// celebration + badges are retired from the dropdown; the lifetime
    /// counter keeps accruing via meterContent's onAppear and can resurface
    /// in Stats.
    private var savingsFootnote: some View {
        HStack(spacing: 7) {
            (Text(verbatim: "≈€\(String(format: "%.2f", lifetimeAndWeeklyEUR))").foregroundStyle(.secondary)
             + Text(" saved").foregroundStyle(.tertiary)
             + Text(verbatim: "   ·   ").foregroundStyle(.tertiary)
             + Text("\(formatTokens(appState.savedTokensThisWeek))").foregroundStyle(.secondary)
             + Text(" tokens this week").foregroundStyle(.tertiary))
                .font(.system(size: 11.5))
            Spacer(minLength: 0)
            Button { mode = .stats } label: {
                Text("Stats›")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }

    /// Total EUR saved (lifetime + this week) using MilestoneTracker's conversion rate.
    private var lifetimeAndWeeklyEUR: Double {
        let liveTokens = MilestoneTracker.shared.lifetimeTokens + appState.savedTokensThisWeek
        return Double(liveTokens) / 1_000_000 * 6.00
    }

    /// Banner shown when the user has enabled exact mode but the latest poll
    /// failed — so the meter is silently falling back to local-JSONL estimates.
    /// Without this, the user sees plausible-looking numbers that can be wildly
    /// off from claude.ai's actual session % (the bug that prompted this banner).
    /// Auto-clears on the next successful poll because `onSnapshot` resets
    /// `exactModeError` to nil in AppDelegate.
    @ViewBuilder
    private var exactModeWarningBanner: some View {
        if appState.exactModeEnabled, let err = appState.exactModeError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Exact mode unavailable — showing local estimates")
                        .font(.caption.weight(.semibold))
                    Text(describe(err))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let action = exactModeWarningAction(err) {
                    Button(action.title, action: action.handler)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(.orange)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
                    )
            )
            .padding(.top, 8)
        }
    }

    private struct ExactModeAction {
        let title: String
        let handler: () -> Void
    }

    /// Contextual one-tap remediation per error kind. Returns nil for cases
    /// where there's no obvious user action (none currently — every error has
    /// a remediation, but kept optional for forward-compat).
    private func exactModeWarningAction(_ err: ExactModeError) -> ExactModeAction? {
        // With the embedded WKWebView session, almost every failure boils
        // down to "you're not actually authenticated" — stale cookie,
        // expired session, never signed in, claude.ai forced re-auth.
        // The right CTA is almost always "Sign in to claude.ai" which
        // opens our embedded sign-in window. Only pure transient HTTP
        // 5xx / timeout / parse errors get a Retry button.
        switch err {
        case .notSignedIn, .noClaudeTab, .safariNotRunning,
             .tabZombieRateLimited, .automationDenied, .invalidResponse:
            return ExactModeAction(title: String(localized: "Sign in to claude.ai")) {
                Task { @MainActor in
                    let signed = await EmbeddedClaudeSession.shared.presentSignIn()
                    if signed { await ExactModeService.shared.refresh() }
                }
            }
        case .httpError(let code) where code == 401 || code == 403:
            return ExactModeAction(title: String(localized: "Sign in to claude.ai")) {
                Task { @MainActor in
                    let signed = await EmbeddedClaudeSession.shared.presentSignIn()
                    if signed { await ExactModeService.shared.refresh() }
                }
            }
        case .httpError, .appleScript, .timeout:
            return ExactModeAction(title: String(localized: "Retry")) {
                Task { await ExactModeService.shared.refresh() }
            }
        }
    }

    /// Identity + status. The binding hero owns the number, so no top-right %.
    /// EXACT is an inverted solid pill with a dot; PRO a soft pill; FREE outlined.
    private var titleRow: some View {
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

    private func pillSoft(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 9.5, weight: .heavy))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(.secondary)
    }

    private func pillFree(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 9.5, weight: .heavy))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .foregroundStyle(.tertiary)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private func emptyState(message: String) -> some View {
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

    private var hairColor: Color { Color.primary.opacity(0.09) }
    private var hairline: some View {
        Rectangle().fill(hairColor).frame(height: 1).padding(.horizontal, 16)
    }
    private var secKick: some View {
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
    private var meterReadout: some View {
        let metrics = [
            displayMetric(for: .session5h),
            displayMetric(for: .weeklyAll),
            displayMetric(for: .weeklySonnet)
        ]
        let binding = metrics
            .filter { $0.percent != nil }
            .max { ($0.percent ?? 0) < ($1.percent ?? 0) }
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
    private func rows(_ metrics: [DisplayMetric]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { idx, m in
                if idx > 0 { Rectangle().fill(hairColor).frame(height: 1) }
                secondaryRow(m)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private struct DisplayMetric: Identifiable {
        let kind: WindowKind
        let title: String         // "Session", "Weekly"
        let subtitle: String      // "5-hour", "all models", "Sonnet only"
        let bindingLabel: String  // "Session (5h)", "Weekly · Sonnet only"
        let percent: Double?
        let resetInSeconds: Int64
        let isExact: Bool
        var id: WindowKind { kind }
    }

    private func displayMetric(for kind: WindowKind) -> DisplayMetric {
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
            title = String(localized: "Weekly")
            subtitle = String(localized: "Sonnet only")
            bindingLabel = String(localized: "Weekly · Sonnet only")
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
    private func bindingHero(_ m: DisplayMetric) -> some View {
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
    private func secondaryRow(_ m: DisplayMetric) -> some View {
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

    private var estimateTag: some View {
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
    private struct UsageBar: View {
        let pct: Double?
        let tint: Color
        var degraded: Bool = false
        var height: CGFloat = 6
        var strongTicks: Bool = false

        var body: some View {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    ForEach([0.80, 0.95], id: \.self) { mark in
                        Rectangle()
                            .fill(Color.primary.opacity(strongTicks ? 0.22 : 0.15))
                            .frame(width: strongTicks ? 1.5 : 1, height: height)
                            .offset(x: w * mark)
                    }
                    if let p = pct {
                        let fillW = max(height, min(w, w * p))
                        Group {
                            if degraded {
                                Stripes().stroke(tint.opacity(0.85), lineWidth: 1.5)
                            } else {
                                Capsule().fill(tint)
                            }
                        }
                        .frame(width: fillW)
                        .clipShape(Capsule())
                    }
                }
            }
            .frame(height: height)
        }
    }

    /// Diagonal hatch for the estimate (degraded) fill.
    private struct Stripes: Shape {
        var spacing: CGFloat = 4
        func path(in rect: CGRect) -> Path {
            var p = Path()
            var x = -rect.height
            while x < rect.width + rect.height {
                p.move(to: CGPoint(x: x, y: rect.height))
                p.addLine(to: CGPoint(x: x + rect.height, y: 0))
                x += spacing
            }
            return p
        }
    }

    /// Wall-clock time this many seconds from now (e.g. "9pm", "Mon 4pm").
    /// Matches claude.ai's "resets 9pm (Europe/Paris)" framing so users
    /// don't have to mentally add countdown to current time.
    private func formatWallClock(_ secondsFromNow: Int64) -> String {
        let target = Date().addingTimeInterval(TimeInterval(secondsFromNow))
        let cal = Calendar.current
        let now = Date()
        let f = DateFormatter()
        f.locale = .current
        let isToday = cal.isDateInToday(target)
        let isTomorrow = cal.isDateInTomorrow(target)
        let withinThreeDays = (target.timeIntervalSince(now)) < 3 * 24 * 3600
        // Include minutes only when the reset isn't on the hour. Anthropic's
        // weekly windows usually reset on the hour ("4pm"), but the session
        // window and API-supplied resets_at can land mid-hour (15:59) — the
        // old hour-only "ha" template floored that to "3pm", which reads as
        // an hour in the past when the countdown says "in 3m".
        let hourTok = cal.component(.minute, from: target) != 0 ? "hmm" : "h"
        if isToday {
            f.setLocalizedDateFormatFromTemplate("\(hourTok)a")
            return f.string(from: target).lowercased()
        }
        if isTomorrow {
            f.setLocalizedDateFormatFromTemplate("\(hourTok)a")
            return "tmrw \(f.string(from: target).lowercased())"
        }
        if withinThreeDays {
            f.setLocalizedDateFormatFromTemplate("EEE\(hourTok)a")
            return f.string(from: target).lowercased()
        }
        f.setLocalizedDateFormatFromTemplate("EEEMMMd\(hourTok)a")
        return f.string(from: target).lowercased()
    }

    /// A row is "degraded" — shown muted with an ≈/estimate tag — when the
    /// user enabled exact mode but this window is falling back to local
    /// JSONL math. That's the case the meter must not dress up as confident:
    /// a local 90% that won't track the server cap. Pure-local users (exact
    /// never enabled) keep the clean display — local-by-design isn't a
    /// degradation, and tagging all three rows would just be noise.
    private func degraded(_ metric: DisplayMetric) -> Bool {
        appState.exactModeEnabled && !metric.isExact
    }

    /// The BAR fill colour — neutral graphite until pressure is real. Colour is
    /// earned, not default: accent blue never touches the bars.
    private func progressTint(for pct: Double) -> Color {
        switch pct {
        case ..<0.8:  return Color.primary.opacity(0.45)
        case ..<0.95: return .orange
        default:      return .red
        }
    }

    /// The NUMBER colour — primary ink until pressure, muted when degraded.
    private func numberColor(pct: Double, degraded deg: Bool) -> Color {
        if deg { return .secondary }
        switch pct {
        case ..<0.8:  return .primary
        case ..<0.95: return .orange
        default:      return .red
        }
    }


    /// Direction A — "The Dock". Four destinations as a compact icon row over
    /// one quiet meta line carrying sign-in STATUS and demoted chrome. Replaces
    /// the old flat 10-row menu (incl. the two inert Run Optimizer / Manage
    /// Hooks rows, which did nothing and duplicated Settings/Project). Pro/Free
    /// already lives in the title pill, so the footer stays pure navigation and
    /// subordinate to the meter above.
    private var dockFooter: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                DockTile(icon: "chart.line.uptrend.xyaxis", label: "Stats") {
                    mode = .stats
                }
                DockTile(icon: "rectangle.split.3x1", label: "Project",
                         badgeText: appState.isPro ? nil : "PRO", badgeStyle: .pro) {
                    ProjectWindowController.shared.show(appState: appState)
                }
                DockTile(icon: "terminal", label: "Cockpit",
                         badgeText: appState.isPro ? "BETA" : "PRO",
                         badgeStyle: appState.isPro ? .beta : .pro) {
                    if appState.isPro {
                        CockpitWindowController.shared.show(appState: appState)
                    } else {
                        mode = .settings(.pro)   // Pro feature → upsell
                    }
                }
                DockTile(icon: "magnifyingglass", label: "Search") {
                    TranscriptSearchWindowController.shared.show()
                }
                DockTile(icon: "gear", label: "Settings") {
                    mode = .settings(.general)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)

            dockMeta
        }
        .padding(.bottom, 8)
    }

    /// The quiet meta line under the dock: sign-in status on the left, demoted
    /// chrome (Usage / About / Quit) on the right, separated from the dock by a
    /// hairline. Sign-in is always tappable (opens the embedded sign-in / re-auth
    /// window) so the user never has to wait for an exact-mode poll to fail first.
    private var dockMeta: some View {
        VStack(spacing: 0) {
            Rectangle().fill(hairColor).frame(height: 1)
            HStack(spacing: 8) {
                Button {
                    Task { @MainActor in
                        let signed = await EmbeddedClaudeSession.shared.presentSignIn()
                        if signed { await ExactModeService.shared.refresh() }
                    }
                } label: {
                    if embeddedSignedIn {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text("claude.ai").foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                            Text("Sign in…").foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                HStack(spacing: 11) {
                    metaLink("Usage", systemImage: "arrow.up.right") {
                        if let url = URL(string: "https://claude.ai/settings/usage") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    metaLink("About") { mode = .settings(.about) }
                    metaLink("Quit") { NSApp.terminate(nil) }
                        .keyboardShortcut("q")
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 9)
            .padding(.top, 8)
        }
        .padding(.horizontal, 5)
        .padding(.top, 7)
    }

    /// A small tertiary text link for the demoted-chrome group in the meta line.
    private func metaLink(_ title: LocalizedStringKey, systemImage: String? = nil,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 9.5))
                }
                Text(title)
            }
            .foregroundStyle(.tertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Settings mode

    private func settingsContent(tab: SettingsTab) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Button { mode = .meter } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                Text("Throttle").font(.system(size: 14.5, weight: .semibold))
                Text("Settings").font(.system(size: 12)).foregroundStyle(.tertiary)
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
            .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 9)

            settingsTabBar(current: tab)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .general:     InlineGeneralPane()
                    case .pro:         InlineProPane()
                    case .assistant:   InlineAssistantPane()
                    case .calibration: InlineCalibrationPane()
                    case .hooks:       InlineHooksPane()
                    case .about:       InlineAboutPane()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 220, maxHeight: 380)
        }
    }

    /// Direction A console tab bar — six terse tabs; active gets accent text +
    /// a 2pt accent underline. One pane scrolls beneath.
    @ViewBuilder
    private func settingsTabBar(current: SettingsTab) -> some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases, id: \.self) { t in
                let on = t == current
                Button { mode = .settings(t) } label: {
                    Text(t.tabLabel)
                        .font(.system(size: 11.5, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .overlay(alignment: .bottom) {
                            if on {
                                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor)
                                    .frame(height: 2).padding(.horizontal, 6)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1)
        }
    }
}

// MARK: - Dock footer kit

private enum DockBadgeStyle { case pro, beta }

/// Tiny floating badge over a dock tile. `.pro` = soft graphite fill (only when
/// Free); `.beta` = transparent with a hairline border — matching the title
/// pills' exact-vs-estimate restraint (no accent, no colour).
private struct DockBadgeView: View {
    let text: String
    let style: DockBadgeStyle
    var body: some View {
        Group {
            switch style {
            case .pro:
                Text(text)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.secondary)
            case .beta:
                Text(text)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .foregroundStyle(.tertiary)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.12), lineWidth: 1))
            }
        }
        .font(.system(size: 8.5, weight: .heavy))
        .tracking(0.4)
    }
}

/// One destination tile in the dock: icon over a small label, a subtle hover
/// fill, and an optional floating badge. Uses `onTapGesture` + `onHover`
/// (the macOS-preferred pattern over Button for hover-reactive cells).
private struct DockTile: View {
    let icon: String
    let label: LocalizedStringKey
    var badgeText: String? = nil
    var badgeStyle: DockBadgeStyle = .beta
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.primary)
                .opacity(0.82)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(hover ? Color.primary.opacity(0.06) : Color.clear)
        )
        .overlay(alignment: .top) {
            if let badgeText {
                DockBadgeView(text: badgeText, style: badgeStyle)
                    .offset(x: 14, y: -1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
    }
}

// MARK: - Settings cockpit kit

private struct SettingsHair: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1).padding(.horizontal, 16)
    }
}

private struct SettingsGroupHeader: View {
    let label: String
    var desc: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(LocalizedStringKey(label)).font(.system(size: 10.5, weight: .semibold))
                .tracking(0.9).textCase(.uppercase).foregroundStyle(.tertiary)
            if let desc {
                Text(LocalizedStringKey(desc)).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 3)
    }
}

/// Flat ≥44pt settings row: title (+ optional sub) left, a trailing control right.
private struct SettingsRow<Trailing: View>: View {
    let title: String
    var sub: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title)).font(.system(size: 13))
                if let sub {
                    Text(LocalizedStringKey(sub)).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .frame(minHeight: 44)
    }
}

/// Quiet caption under a group, full-bleed with 16pt padding.
private struct SettingsNote: View {
    let text: String
    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.system(size: 11)).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)
    }
}

/// Bordered settings button (`.primary` = accent fill). Calm, native-ish.
private struct SettingsButton: View {
    let title: String
    var systemImage: String? = nil
    var primary: Bool = false
    var role: ButtonRole? = nil
    let action: () -> Void
    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11)) }
                Text(LocalizedStringKey(title))
            }
            .font(.system(size: 12.5, weight: primary ? .semibold : .medium))
            .padding(.horizontal, 13).padding(.vertical, 7)
            .foregroundStyle(primary ? AnyShapeStyle(Color.white)
                             : AnyShapeStyle(role == .destructive ? Color.red : Color.primary))
            .background {
                if primary { RoundedRectangle(cornerRadius: 8).fill(Color.accentColor) }
                else { RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), lineWidth: 1) }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - First-run inline view

/// First-run onboarding — "The Living Meter" (Direction C). The real meter sits
/// at the top, empty and ghosted, and fills in as the user answers; each answer
/// collapses to a confirmed row. Onboarding IS the product. See UI-SPEC-onboarding.md.
private struct FirstRunInline: View {
    @Environment(AppState.self) private var appState

    enum PlanChoice: String, CaseIterable, Identifiable {
        case pro, max5x, max20x, skip
        var id: String { rawValue }
        var name: String {
            switch self {
            case .pro:    return "Pro"
            case .max5x:  return "Max 5×"
            case .max20x: return "Max 20×"
            case .skip:   return String(localized: "Skip — auto-calibrate")
            }
        }
        var price: String? {
            switch self {
            case .pro: return "€19/mo"; case .max5x: return "€90/mo"
            case .max20x: return "€180/mo"; case .skip: return nil
            }
        }
        var blurb: String {
            switch self {
            case .pro:    return String(localized: "Most solo developers")
            case .max5x:  return String(localized: "Heavy daily Claude Code")
            case .max20x: return String(localized: "All-day, multi-agent")
            case .skip:   return String(localized: "Throttle learns your caps from real usage over a few days.")
            }
        }
        /// Display caps — mirror the real presets written in `apply()`.
        var session: String? {
            switch self { case .pro: return "4M"; case .max5x: return "8M"; case .max20x: return "20M"; case .skip: return nil }
        }
        var weekly: String? {
            switch self { case .pro: return "60M"; case .max5x: return "200M"; case .max20x: return "800M"; case .skip: return nil }
        }
    }

    @State private var pick: PlanChoice? = nil
    @State private var enableLoginItems: Bool = true
    @State private var signedIn: Bool = false
    /// Conversational step: 0 = ask plan, 1 = ask launch, 2 = done.
    @State private var qi: Int = 0

    private let demo = (session: 0.47, weekly: 0.12, sonnet: 0.03)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHero
            livingMeter
            progressDots
            thread
        }
        .task { signedIn = ExactModeService.shared.hasFreshSnapshot }
    }

    private var brandHero: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 26)).foregroundStyle(.primary.opacity(0.9))
                .padding(.bottom, 8)
            Text("Throttle").font(.system(size: 17, weight: .semibold))
            Text("Accurate Claude Code usage, in your menu bar.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 4)
    }

    // MARK: - Living meter preview

    private var livingMeter: some View {
        let filled = pick != nil
        let auto = pick == .skip
        return VStack(alignment: .leading, spacing: 0) {
            Text("YOUR METER")
                .font(.system(size: 8.5, weight: .heavy)).tracking(1)
                .foregroundStyle(.tertiary).padding(.bottom, 9)
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 14)).foregroundStyle(.primary.opacity(0.9))
                Text("Throttle").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if filled {
                    Text(auto ? "AUTO" : "PRO").font(.system(size: 9, weight: .heavy))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 10)
            meterRow("Session", "5-hour", cap: pick?.session, pct: demo.session, auto: auto, filled: filled)
            meterDivider
            meterRow("Weekly", "all models", cap: pick?.weekly, pct: demo.weekly, auto: auto, filled: filled)
            meterDivider
            meterRow("Weekly", "Sonnet only", cap: pick?.weekly, pct: demo.sonnet, auto: auto, filled: filled)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 13).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
        .animation(.easeOut(duration: 0.55), value: pick)
    }

    private var meterDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
    }

    @ViewBuilder
    private func meterRow(_ name: String, _ sub: String, cap: String?, pct: Double, auto: Bool, filled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name).font(.system(size: 12, weight: .medium)).opacity(filled ? 1 : 0.5)
                Text(sub).font(.system(size: 10.5)).foregroundStyle(.secondary).opacity(filled ? 1 : 0.5)
                Spacer(minLength: 0)
                if filled {
                    Text(auto ? "auto" : "cap \(cap ?? "")")
                        .font(.system(size: 11).monospaced()).foregroundStyle(.secondary)
                } else {
                    Text(verbatim: "— —").font(.system(size: 11).monospaced()).foregroundStyle(.tertiary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    if filled {
                        Capsule().fill(Color.primary.opacity(auto ? 0.28 : 0.45))
                            .frame(width: auto ? geo.size.width : max(4, geo.size.width * pct))
                    }
                }
            }
            .frame(height: 5)
        }
        .padding(.vertical, 8)
    }

    private var progressDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(qi >= i ? Color.accentColor : Color.primary.opacity(0.10)).frame(height: 3)
            }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 2)
    }

    // MARK: - Conversational thread

    @ViewBuilder
    private var thread: some View {
        VStack(alignment: .leading, spacing: 0) {
            if qi >= 1 {
                confirmedRow(label: "Plan", value: planSummary) { withAnimation { qi = 0 } }
            }
            if qi == 0 {
                qCard("Which Claude plan are you on?",
                      "Pick one and watch your meter fill in. Reads ~/.claude/projects on this Mac.")
                planPicker
            } else if qi == 1 {
                qCard("Keep Throttle in your menu bar?", "Launch it automatically when you log in.")
                launchRow
                actionBar("Looks good") { withAnimation { qi = 2 } }
            } else {
                confirmedRow(label: "Launch at login", value: enableLoginItems ? "On" : "Off") { withAnimation { qi = 1 } }
                exactTeaser
                actionBar("Open my meter") { apply() }
            }
        }
    }

    private var planSummary: String {
        guard let p = pick else { return String(localized: "Auto-calibrate") }
        if let s = p.session, let w = p.weekly { return "\(p.name) · \(s)/\(w)" }
        return p.name
    }

    private func qCard(_ prompt: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(prompt).font(.system(size: 14, weight: .semibold))
            Text(sub).font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 6)
    }

    private var planPicker: some View {
        VStack(spacing: 6) {
            ForEach(PlanChoice.allCases) { planButton($0) }
        }
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 4)
    }

    @ViewBuilder
    private func planButton(_ p: PlanChoice) -> some View {
        let on = pick == p
        Button {
            withAnimation(.easeOut(duration: 0.5)) { pick = p; qi = 1 }
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    if on {
                        Circle().fill(Color.accentColor)
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    } else {
                        Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1.5)
                    }
                }
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(p.name).font(.system(size: 13.5, weight: .medium))
                        if let price = p.price {
                            Text(price).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                    Text(p.blurb).font(.system(size: 11)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let s = p.session, let w = p.weekly {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(s) · \(w)").font(.system(size: 13).monospaced())
                        Text("SESSION · WEEKLY").font(.system(size: 8.5, weight: .medium)).tracking(0.4)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 11).fill(on ? Color.accentColor.opacity(0.07) : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(
                        on ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: on ? 2 : 1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func confirmedRow(label: String, value: String, onEdit: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accentColor)
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 17, height: 17)
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 12, weight: .medium))
            Button { onEdit() } label: {
                Text("Edit").font(.system(size: 11)).foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1).padding(.horizontal, 16) }
    }

    private var launchRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Launch at login").font(.system(size: 13))
                Text("Keep the meter in your menu bar.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $enableLoginItems).labelsHidden().toggleStyle(.switch).tint(.accentColor)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var exactTeaser: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(.tertiary)
            (Text("Want server-true numbers? Turn on ").foregroundStyle(.tertiary)
             + Text("Exact mode").foregroundStyle(.secondary).fontWeight(.semibold)
             + Text(" later in Settings.").foregroundStyle(.tertiary))
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private func actionBar(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 14)
    }

    private func apply() {
        if enableLoginItems { try? LoginItemService.setEnabled(true) }
        let preset: [(WindowKind, Int)]? = {
            switch pick {
            case .pro:    return [(.session5h, 4_000_000), (.weeklyAll, 60_000_000), (.weeklySonnet, 60_000_000)]
            case .max5x:  return [(.session5h, 8_000_000), (.weeklyAll, 200_000_000), (.weeklySonnet, 200_000_000)]
            case .max20x: return [(.session5h, 20_000_000), (.weeklyAll, 800_000_000), (.weeklySonnet, 800_000_000)]
            case .skip, .none: return nil
            }
        }()
        if let preset,
           let url = try? DatabaseManager.databaseURL(),
           let pool = try? DatabasePool(path: url.path) {
            try? pool.write { db in
                for (kind, cap) in preset {
                    try CalibrationEngine.setManual(in: db, kind: kind, capTokens: cap)
                }
            }
        }
        appState.markFirstRunDone()
        appState.refresh()
        if signedIn {
            appState.setExactModeEnabled(true)
            ExactModeService.shared.start()
        }
    }
}

// MARK: - Inline Settings panes

private struct InlineGeneralPane: View {
    @Environment(AppState.self) private var appState
    @State private var loginItemsEnabled: Bool = LoginItemService.isEnabled
    @State private var cockpitOnTop: Bool = CockpitWindowController.alwaysOnTop
    @State private var notificationsOn: Bool = ThresholdNotifier.shared.isEnabled
    @State private var calendarStatus: String = ""
    @State private var conciseClaudeCode: Bool =
        FileManager.default.fileExists(atPath: InlineGeneralPane.conciseFlagPath)
    @AppStorage("throttleAutoPauseEnabled") private var autoPauseEnabled = false
    @State private var autopilotOn: Bool = AutopilotService.isEnabled
    @State private var apMemory: Bool = AutopilotService.archiveStaleMemory
    @State private var apSkills: Bool = AutopilotService.archiveDeadSkills
    @State private var semanticAutoIndex: Bool = SemanticAutoIndexer.isEnabled
    @State private var showingLedger = false
    @State private var ledger: [AutopilotService.Entry] = []
    @State private var autopilotBusy = false
    @State private var activeStyle = OutputStyleManager.activeName()
    @State private var dropImagesAsText = UserDefaults.standard.bool(forKey: DroppableTerminalView.ocrDefaultsKey)
    @State private var tokoptOn = TokoptHookInstaller.isInstalled()
    @State private var tokoptNote = ""
    @State private var memoryOn = TranscriptMemoryInstaller.isInstalled()
    @State private var memoryNote = ""

    /// Flag file the SessionStart hook reads to inject a terse-output directive
    /// into every Claude Code session. App writes it (non-sandboxed); hook reads it.
    static var conciseFlagPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/throttle-concise").path
    }
    private func setConciseFlag(_ on: Bool) {
        if on { FileManager.default.createFile(atPath: Self.conciseFlagPath, contents: Data()) }
        else { try? FileManager.default.removeItem(atPath: Self.conciseFlagPath) }
    }

    /// Save the generated team hardening policy as managed-settings.json.
    private func exportTeamPolicy() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "managed-settings.json"
        panel.message = "Deploy this to \(TeamPolicyService.deployPath) via MDM to enforce across a team."
        panel.prompt = "Export Policy"
        if panel.runModal() == .OK, let url = panel.url {
            try? TeamPolicyService.generate().write(to: url, atomically: true, encoding: .utf8)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            autopilotGroup
            SettingsGroupHeader(label: "General")
            SettingsRow(title: "Launch at login") {
                Toggle("", isOn: $loginItemsEnabled).labelsHidden().toggleStyle(.switch).tint(.accentColor)
                    .onChange(of: loginItemsEnabled) { _, new in try? LoginItemService.setEnabled(new) }
            }
            SettingsHair()
            SettingsRow(title: "Keep Cockpit on top",
                        sub: "Float the Cockpit window above other apps — a companion you watch while working.") {
                Toggle("", isOn: $cockpitOnTop).labelsHidden().toggleStyle(.switch).tint(.accentColor)
                    .onChange(of: cockpitOnTop) { _, new in CockpitWindowController.alwaysOnTop = new }
            }
            SettingsHair()
            SettingsRow(title: "Notify at 80% and 95%",
                        sub: "A quiet banner as each window nears its cap.") {
                Toggle("", isOn: $notificationsOn).labelsHidden().toggleStyle(.switch).tint(.accentColor)
                    .onChange(of: notificationsOn) { _, new in ThresholdNotifier.shared.setEnabled(new) }
            }
            SettingsHair()
            SettingsRow(title: "Weekly-reset reminder",
                        sub: calendarStatus.isEmpty ? "Add a Monday reset event to Calendar." : calendarStatus) {
                SettingsButton(title: "Add to Calendar", systemImage: "calendar") {
                    Task {
                        let result = await CalendarReminderService.addNextWeeklyReset(
                            in: appState.snapshot, exact: appState.exactSnapshot)
                        await MainActor.run { handleCalendarResult(result) }
                    }
                }
            }
            SettingsHair()
            SettingsRow(title: "Auto-pause near the cap",
                        sub: "Off by default. At 95% with the wall under 5 min away, Throttle shows a 10-second cancelable countdown, then waits for a quiet moment in the transcript (no stream/write in flight) before freezing (SIGSTOP) the runaway session — or all live ones if none is looping. Reversible: resume anytime, nothing lost.") {
                Toggle("", isOn: $autoPauseEnabled).labelsHidden().toggleStyle(.switch).tint(.accentColor)
            }
            SettingsHair()
            SettingsRow(title: "Concise Claude Code replies",
                        sub: "Inject a terse-output directive into every Claude Code session via the hook.") {
                Toggle("", isOn: $conciseClaudeCode).labelsHidden().toggleStyle(.switch).tint(.accentColor)
                    .onChange(of: conciseClaudeCode) { _, on in setConciseFlag(on) }
            }
            SettingsHair()
            SettingsRow(title: "Claude Code output style",
                        sub: "Active: \(activeStyle) — the reply voice for every claude session (terminal + Cockpit). Pick a built-in, or create your own (Caveman, Concise…).") {
                HStack(spacing: 6) {
                    if !appState.isPro {
                        Text("PRO").font(.system(size: 9, weight: .heavy)).tracking(0.3)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.secondary)
                    }
                    SettingsButton(title: "Manage…") {
                        if appState.isPro { OutputStyleWindowController.shared.show() }
                    }
                    .disabled(!appState.isPro)
                }
            }
            SettingsHair()
            SettingsRow(title: "Compress command output",
                        sub: tokoptNote.isEmpty
                            ? "Installs a PostToolUse hook that strips ANSI, dedups and trims verbose CLI output before Claude sees it — fewer tokens, errors always passed through raw. Reversible; restart Claude Code after."
                            : tokoptNote) {
                HStack(spacing: 6) {
                    if !appState.isPro {
                        Text("PRO").font(.system(size: 9, weight: .heavy)).tracking(0.3)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.secondary)
                    }
                    Toggle("", isOn: appState.isPro ? $tokoptOn : .constant(false))
                        .labelsHidden().toggleStyle(.switch).tint(.accentColor)
                        .disabled(!appState.isPro)
                        .onChange(of: tokoptOn) { _, on in
                            guard appState.isPro else { return }
                            Task.detached(priority: .utility) {
                                if on { _ = try? TokoptHookInstaller.install() }
                                else { try? TokoptHookInstaller.remove() }
                            }
                            tokoptNote = on
                                ? "Installed — restart Claude Code to start compressing."
                                : "Removed — restart Claude Code."
                        }
                }
            }
            SettingsHair()
            SettingsRow(title: "Throttle as an MCP source",
                        sub: memoryNote.isEmpty
                            ? "Installs a local MCP server so Claude can ask Throttle about ITSELF mid-session: search your past sessions, check budget headroom (how much before the 5-hour cap), session cost, and which loaded tools went unused. 100% local + read-only. Reversible; restart Claude Code after."
                            : memoryNote) {
                HStack(spacing: 6) {
                    if !appState.isPro {
                        Text("PRO").font(.system(size: 9, weight: .heavy)).tracking(0.3)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.secondary)
                    }
                    Toggle("", isOn: appState.isPro ? $memoryOn : .constant(false))
                        .labelsHidden().toggleStyle(.switch).tint(.accentColor)
                        .disabled(!appState.isPro)
                        .onChange(of: memoryOn) { _, on in
                            guard appState.isPro else { return }
                            Task.detached(priority: .utility) {
                                if on { _ = try? TranscriptMemoryInstaller.install() }
                                else { try? TranscriptMemoryInstaller.remove() }
                            }
                            memoryNote = on
                                ? "Installed — restart Claude Code, then ask it your budget headroom, cost, dead tools, or to search past sessions."
                                : "Removed — restart Claude Code."
                        }
                }
            }
            SettingsHair()
            SettingsRow(title: "Cockpit: drop images as OCR text",
                        sub: "Drop a screenshot into a Cockpit session as locally-OCR'd text (≈80–90% fewer tokens than a vision image) — loses the visual, so hold ⌥ while dropping to flip per-drop.") {
                Toggle("", isOn: $dropImagesAsText).labelsHidden().toggleStyle(.switch).tint(.accentColor)
                    .onChange(of: dropImagesAsText) { _, on in
                        UserDefaults.standard.set(on, forKey: DroppableTerminalView.ocrDefaultsKey)
                    }
            }
            SettingsHair()
            SettingsRow(title: "Team policy (managed-settings.json)",
                        sub: "Export a Claude Code hardening policy (deny rules, model, output-style) for an admin to deploy across a team via MDM. 100% local — Throttle generates it, you distribute it.") {
                HStack(spacing: 6) {
                    if !appState.isPro {
                        Text("PRO").font(.system(size: 9, weight: .heavy)).tracking(0.3)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.secondary)
                    }
                    SettingsButton(title: "Export…") { if appState.isPro { exportTeamPolicy() } }
                        .disabled(!appState.isPro)
                }
            }
            SettingsHair()
            SettingsRow(title: "Software updates", sub: updatesSubtitle) {
                SettingsButton(title: "Check now") { UpdaterService.shared.checkForUpdates() }
            }
            SettingsNote(text: "Throttle \(currentVersionLabel) · updates are signed and verified before install.")
        }
        .sheet(isPresented: $showingLedger) { autopilotLedgerSheet }
        .onReceive(NotificationCenter.default.publisher(for: .outputStyleChanged)) { _ in
            activeStyle = OutputStyleManager.activeName()
        }
    }

    // MARK: - Autopilot

    @ViewBuilder
    private var autopilotGroup: some View {
        SettingsGroupHeader(label: "Autopilot")
        SettingsRow(title: "Optimize Claude Code system-wide",
                    sub: "Installs a concise output-style (every session stays terse, reasoning untouched) + a usage statusline (live headroom in every terminal tab). 100% local, reversible.") {
            HStack(spacing: 6) {
                if !appState.isPro {
                    Text("PRO").font(.system(size: 9, weight: .heavy)).tracking(0.3)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                }
                Toggle("", isOn: appState.isPro ? $autopilotOn : .constant(false))
                    .labelsHidden().toggleStyle(.switch).tint(.accentColor)
                    .disabled(!appState.isPro)
                    .onChange(of: autopilotOn) { _, on in
                        guard appState.isPro else { return }
                        AutopilotService.isEnabled = on
                        guard on else { return }
                        autopilotBusy = true
                        Task {
                            let made = await Task.detached(priority: .utility) { AutopilotService.runPass() }.value
                            ledger = AutopilotService.load()
                            autopilotBusy = false
                            _ = made
                        }
                    }
            }
        }
        SettingsHair()
        SettingsRow(title: "Auto-archive stale memory",
                    sub: "Off by default — the 30-day heuristic is blunt. Never touches MEMORY.md. Reversible.") {
            Toggle("", isOn: $apMemory).labelsHidden().toggleStyle(.switch).tint(.orange)
                .disabled(!autopilotOn)
                .onChange(of: apMemory) { _, on in AutopilotService.archiveStaleMemory = on }
        }
        SettingsHair()
        SettingsRow(title: "Auto-archive dead skills",
                    sub: "Off by default — never invoked ≠ unwanted. Skills named in your CLAUDE.md are kept. Reversible.") {
            Toggle("", isOn: $apSkills).labelsHidden().toggleStyle(.switch).tint(.orange)
                .disabled(!autopilotOn)
                .onChange(of: apSkills) { _, on in AutopilotService.archiveDeadSkills = on }
        }
        SettingsHair()
        SettingsRow(title: "Semantic project index",
                    sub: "Off by default. Builds a local on-device index of your projects so throttle_semantic_search finds code by meaning. CPU-heavy; auto-paused under memory pressure. 100% local; updates incrementally on launch.") {
            Toggle("", isOn: $semanticAutoIndex).labelsHidden().toggleStyle(.switch).tint(.accentColor)
                .onChange(of: semanticAutoIndex) { _, on in SemanticAutoIndexer.isEnabled = on }
        }
        SettingsHair()
        SettingsRow(title: "Activity log", sub: autopilotStatusSub) {
            if autopilotBusy {
                ProgressView().controlSize(.small)
            } else {
                SettingsButton(title: "Review & undo…") {
                    ledger = AutopilotService.load()
                    showingLedger = true
                }
            }
        }
        SettingsNote(text: "Manual one-tap optimizers (transcript trim, dedup hoist) live in the Cockpit — they touch live content, so they stay deliberate.")
    }

    private var autopilotStatusSub: String {
        let entries = AutopilotService.load()
        let active = entries.filter { !$0.undone }.count
        if !AutopilotService.isEnabled { return "Off — turn on to keep your setup optimized." }
        if let last = AutopilotService.lastRun {
            return "\(active) active change\(active == 1 ? "" : "s") · last run \(formatRelative(last))"
        }
        return entries.isEmpty ? "On — first pass runs shortly." : "\(active) active change\(active == 1 ? "" : "s")"
    }

    private var autopilotLedgerSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Autopilot activity").font(.system(size: 15, weight: .semibold))
                    Text("Everything Throttle changed on your behalf. Each is reversible — nothing left your Mac.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Done") { showingLedger = false }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            if ledger.isEmpty {
                Text("No changes yet.").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 36)
            } else {
                ScrollView { VStack(spacing: 0) { ForEach(ledger) { ledgerRow($0) } } }
            }
            Divider()
            HStack {
                Button("Undo all") {
                    AutopilotService.undoAll(); ledger = AutopilotService.load()
                }
                .disabled(ledger.allSatisfy { $0.undone })
                Spacer()
                Button("Disable & undo everything", role: .destructive) {
                    AutopilotService.disable(undoEverything: true)
                    autopilotOn = false; ledger = AutopilotService.load(); showingLedger = false
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 540, height: 440)
    }

    private func ledgerRow(_ e: AutopilotService.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ledgerIcon(e.kind))
                .font(.system(size: 12)).foregroundStyle(e.undone ? .tertiary : .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.summary).font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(e.undone ? .tertiary : .primary)
                    .strikethrough(e.undone).lineLimit(2)
                if let why = e.detail, !e.undone {
                    Text(why).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(formatRelative(e.timestamp)).font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            if e.undone {
                Text("undone").font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                Button("Undo") { _ = AutopilotService.undo(e.id); ledger = AutopilotService.load() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1) }
    }

    private func ledgerIcon(_ k: AutopilotService.Entry.Kind) -> String {
        switch k {
        case .outputStyle: return "text.alignleft"
        case .statusline:  return "menubar.rectangle"
        case .memory:      return "clock.badge.xmark"
        case .skills:      return "wrench.adjustable"
        }
    }

    private var updatesSubtitle: String {
        if let last = UpdaterService.shared.lastCheckDate {
            return "Auto-checks daily · last checked \(formatRelative(last))"
        }
        return "Auto-checks daily · not checked yet"
    }

    private func handleCalendarResult(_ result: CalendarReminderService.Result) {
        switch result {
        case .added:        calendarStatus = "✓ Event added to your default calendar."
        case .denied:       calendarStatus = "Calendar access denied — enable in System Settings."
        case .noResetTime:  calendarStatus = "No reset time available yet — keep using Claude Code."
        case .error(let m): calendarStatus = "Error: \(m)"
        }
    }

    private func formatRelative(_ date: Date) -> String {
        let secs = -Int(date.timeIntervalSinceNow)
        if secs < 60 { return "\(secs)s ago" }
        let m = secs / 60
        if m < 60 { return "\(m)m ago" }
        return "\(m / 60)h \(m % 60)m ago"
    }

    private var currentVersionLabel: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(v) (\(b))"
    }

}

// MARK: - Pro pane (license + Exact mode)

private struct InlineProPane: View {
    @Environment(AppState.self) private var appState
    @State private var licenseStatus: String = ""
    @State private var activating = false
    @State private var connectionStatus: String = ""
    @State private var testing = false
    @State private var signedIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            licenseBlock
            SettingsHair()
            exactBlock
        }
        .task { signedIn = ExactModeService.shared.hasFreshSnapshot }
    }

    // MARK: License

    @ViewBuilder
    private var licenseBlock: some View {
        let trial = TrialService.shared
        let hasKey = LicenseService.shared.currentKey != nil
        let trialActive = trial.isActive && !hasKey
        SettingsGroupHeader(label: "License")
        if let key = LicenseService.shared.currentKey {
            SettingsRow(title: "Throttle Pro", sub: licenseSubtitle(key: key)) {
                Text("PRO").font(.system(size: 9.5, weight: .heavy))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer(minLength: 0)
                SettingsButton(title: "Deactivate this Mac", role: .destructive) {
                    Task {
                        await LicenseService.shared.deactivate()
                        appState.refreshProStatus()
                        licenseStatus = String(localized: "Deactivated.")
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 10)
        } else if trialActive {
            trialBannerView(daysLeft: trial.daysLeft)
            buyRow
        } else {
            SettingsNote(text: "Unlock Exact mode, Stats history and projections.")
            buyRow
        }
        if !licenseStatus.isEmpty {
            Text(licenseStatus)
                .font(.system(size: 11))
                .foregroundStyle(licenseStatus.hasPrefix("✓") || licenseStatus.hasPrefix("Deactiv") ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.bottom, 10)
        }
    }

    private func licenseSubtitle(key: String) -> String {
        let masked = String(key.prefix(8)) + "····" + String(key.suffix(4))
        if let exp = LicenseService.shared.expiresAt {
            return "Key \(masked) · renews \(exp.formatted(date: .abbreviated, time: .omitted))"
        }
        return "Key \(masked)"
    }

    private var buyRow: some View {
        HStack(spacing: 9) {
            SettingsButton(title: "Buy Pro · €29", primary: true) {
                if let url = URL(string: "https://lorislab.fr/throttle/buy") { NSWorkspace.shared.open(url) }
            }
            Button {
                activateFromClipboard()
            } label: {
                Text("Paste license key").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .disabled(activating)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.bottom, 11)
    }

    private func trialBannerView(daysLeft: Int) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "bolt.fill").font(.system(size: 12)).foregroundStyle(.secondary)
            (Text("\(daysLeft)").font(.system(size: 12, weight: .semibold).monospacedDigit())
             + Text(daysLeft == 1 ? " day left in your Pro trial." : " days left in your Pro trial."))
                .font(.system(size: 12))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 10)
    }

    private func activateFromClipboard() {
        guard let raw = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            licenseStatus = String(localized: "Clipboard is empty. Copy the key from your purchase email first.")
            return
        }
        guard raw.uppercased().hasPrefix("THROTTLE-") else {
            licenseStatus = String(localized: "That doesn't look like a Throttle license key (starts with THROTTLE-).")
            return
        }
        activating = true
        licenseStatus = String(localized: "Activating…")
        Task {
            let result = await LicenseService.shared.activate(key: raw.uppercased())
            await MainActor.run {
                activating = false
                switch result {
                case .success:
                    licenseStatus = String(localized: "✓ Pro activated on this Mac.")
                    appState.refreshProStatus()
                case .failure(let err):
                    licenseStatus = describeLicenseError(err)
                }
            }
        }
    }

    private func describeLicenseError(_ err: LicenseService.ActivationError) -> String {
        switch err {
        case .invalidKey:           return String(localized: "Invalid license key.")
        case .machineLimitReached:  return String(localized: "Already activated on 3 Macs. Deactivate one first.")
        case .revoked:              return String(localized: "License revoked. Contact support@lorislab.fr.")
        case .verificationFailed:   return String(localized: "Server response failed signature check. Don't trust this network.")
        case .network(let m):       return String(localized: "Network error: \(m)")
        case .server(let code):     return String(localized: "Server error \(code). Try again later.")
        case .decode(let m):        return String(localized: "Couldn't decode response: \(m)")
        }
    }

    // MARK: Exact mode

    @ViewBuilder
    private var exactBlock: some View {
        SettingsGroupHeader(label: "Exact mode", desc: "Pro")
        if !appState.isPro {
            VStack(spacing: 6) {
                Text("Read server-true usage")
                    .font(.system(size: 12.5, weight: .medium))
                Text("Polls claude.ai so figures aren't local estimates.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                SettingsButton(title: "Buy Pro · €29", primary: true) {
                    if let url = URL(string: "https://lorislab.fr/throttle/buy") { NSWorkspace.shared.open(url) }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(13)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16).padding(.vertical, 6)
        } else {
            SettingsRow(title: "Read server-true usage",
                        sub: "Polls claude.ai so figures aren't local estimates.") {
                Toggle("", isOn: Binding(
                    get: { appState.exactModeEnabled },
                    set: { on in
                        appState.setExactModeEnabled(on)
                        if on { ExactModeService.shared.start() }
                        else { ExactModeService.shared.stop(); appState.exactSnapshot = nil }
                    }
                )).labelsHidden().toggleStyle(.switch).tint(.accentColor)
            }
            if appState.exactModeEnabled {
                exactSteps
                exactStatus
            }
        }
    }

    private var exactSteps: some View {
        VStack(spacing: 0) {
            exactStep(idx: 1, done: true, "Open claude.ai in Safari",
                      action: SettingsButton(title: "Open") { ExactModeService.shared.openSignInPage() })
            SettingsHair()
            exactStep(idx: 2, done: signedIn, "Sign in to claude.ai",
                      action: signedIn ? nil : SettingsButton(title: "Sign in") {
                          Task { @MainActor in
                              let ok = await EmbeddedClaudeSession.shared.presentSignIn()
                              if ok { signedIn = true; _ = await ExactModeService.shared.refresh() }
                          }
                      })
            SettingsHair()
            exactStep(idx: 3, done: appState.exactSnapshot != nil, "Test connection",
                      action: SettingsButton(title: testing ? "Testing…" : "Test") { testConnection() })
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func exactStep(idx: Int, done: Bool, _ title: String, action: SettingsButton?) -> some View {
        HStack(spacing: 11) {
            ZStack {
                if done {
                    Circle().fill(Color.primary)
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                } else {
                    Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1)
                    Text("\(idx)").font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
            Text(title).font(.system(size: 12.5)).foregroundStyle(done ? .secondary : .primary)
            Spacer(minLength: 8)
            if let action { action }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    @ViewBuilder
    private var exactStatus: some View {
        if let err = appState.exactModeError {
            statusBanner(ok: false, text: describe(err))
        } else if !connectionStatus.isEmpty {
            statusBanner(ok: connectionStatus.hasPrefix("✓"), text: connectionStatus)
        } else if let snap = appState.exactSnapshot {
            statusBanner(ok: true, text: "Working", meta: "last poll \(relative(snap.fetchedAt))")
        }
    }

    private func statusBanner(ok: Bool, text: String, meta: String? = nil) -> some View {
        HStack(spacing: 9) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let meta { Text(meta).font(.system(size: 11)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)
    }

    private func testConnection() {
        testing = true
        connectionStatus = ""
        Task {
            let result = await ExactModeService.shared.refresh()
            await MainActor.run {
                testing = false
                switch result {
                case .success:
                    connectionStatus = String(localized: "✓ Working. Exact numbers now showing in the meter.")
                    signedIn = true
                    if appState.exactModeEnabled { ExactModeService.shared.start() }
                case .failure(let err):
                    signedIn = false
                    connectionStatus = describe(err)
                }
            }
        }
    }

    private func relative(_ date: Date) -> String {
        let secs = -Int(date.timeIntervalSinceNow)
        if secs < 60 { return "\(secs)s ago" }
        let m = secs / 60
        if m < 60 { return "\(m)m ago" }
        return "\(m / 60)h \(m % 60)m ago"
    }
}

/// Shared file-private formatter for ExactModeError messages, used by both
/// InlineGeneralPane (Settings) and DropdownView (the meter banner).
fileprivate func describe(_ err: ExactModeError) -> String {
    switch err {
    case .notSignedIn:        return "Not signed in to claude.ai in Safari. Sign in and re-test."
    case .noClaudeTab:        return "Couldn't open a claude.ai tab in Safari. Open one manually and re-test."
    case .safariNotRunning:   return "Safari isn't running. Open it (or click 'Open claude.ai in Safari') and re-test."
    case .automationDenied:   return "macOS denied automation. Open System Settings → Privacy & Security → Automation → Throttle → enable Safari, then re-test."
    case .httpError(let code): return "HTTP \(code)"
    case .invalidResponse:    return "Bad response from claude.ai."
    case .appleScript(let s): return "AppleScript: \(s)"
    case .timeout:            return "Timed out."
    case .tabZombieRateLimited:
        return "Safari discarded the claude.ai tab. Open the tab once to wake it; Throttle will resume polling automatically."
    }
}

private struct InlineCalibrationPane: View {
    @Environment(AppState.self) private var appState
    @State private var caps: [WindowKind: Int] = [:]
    @State private var recalPct: [WindowKind: Int] = [
        .session5h: 50, .weeklyAll: 50, .weeklySonnet: 50
    ]

    /// Preset buttons — chosen to cover Pro / Max 5× / Max 20× ballparks for each window.
    /// Avoids TextField, which on macOS 26.5 triggers a RealityBridge/Metal preload
    /// crash inside the menu-bar popover. Power-user manual entry returns in v1.1
    /// once Apple ships a fix or we move calibration into a dedicated NSWindow.
    private static let presets: [WindowKind: [(label: String, tokens: Int)]] = [
        .session5h: [
            ("4M",  4_000_000),
            ("8M",  8_000_000),
            ("20M", 20_000_000)
        ],
        .weeklyAll: [
            ("60M",  60_000_000),
            ("200M", 200_000_000),
            ("800M", 800_000_000)
        ],
        .weeklySonnet: [
            ("60M",  60_000_000),
            ("200M", 200_000_000),
            ("800M", 800_000_000)
        ]
    ]

    private static let planLabels = ["Pro", "Max 5×", "Max 20×"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader(label: "Calibration", desc: "Set your three usage caps")
            calWindow(.session5h, "Session", "5-hour")
            SettingsHair()
            calWindow(.weeklyAll, "Weekly", "all models")
            SettingsHair()
            calWindow(.weeklySonnet, "Weekly", "Sonnet only")
            SettingsHair()
            recalBlock
            SettingsHair()
            HStack {
                Spacer(minLength: 0)
                SettingsButton(title: "Reset all", role: .destructive) { resetAll() }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .task { await loadCurrent() }
    }

    @ViewBuilder
    private func calWindow(_ kind: WindowKind, _ name: String, _ sub: String) -> some View {
        let selected = caps[kind] ?? 0
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(name).font(.system(size: 12.5, weight: .semibold))
                Text(sub).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("cap \(formatTokens(selected))")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(Array((Self.presets[kind] ?? []).enumerated()), id: \.element.tokens) { i, preset in
                    calChip(label: preset.label,
                            plan: Self.planLabels[min(i, Self.planLabels.count - 1)],
                            on: selected == preset.tokens) { save(kind: kind, capTokens: preset.tokens) }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private func calChip(label: String, plan: String, on: Bool, action: @escaping () -> Void) -> some View {
        let fg: Color = on ? .accentColor : .secondary
        let planFg: Color = on ? .accentColor.opacity(0.8) : .secondary.opacity(0.6)
        let stroke: Color = on ? .accentColor.opacity(0.45) : .primary.opacity(0.12)
        let fill: Color = on ? .accentColor.opacity(0.13) : .clear
        return Button(action: action) {
            HStack(spacing: 5) {
                Text(label).font(.system(size: 11.5).monospacedDigit())
                Text(plan).font(.system(size: 10)).foregroundStyle(planFg)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .foregroundStyle(fg)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(fill)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(stroke, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }

    private var recalBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Recalibrate — read claude.ai's % and Apply")
                .font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                .textCase(.uppercase).foregroundStyle(.tertiary)
            ForEach([WindowKind.session5h, .weeklyAll, .weeklySonnet], id: \.self) { kind in
                recalRow(kind)
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 12)
    }

    @ViewBuilder
    private func recalRow(_ kind: WindowKind) -> some View {
        let used = window(for: kind)?.usedTokens ?? 0
        let pct = recalPct[kind] ?? 50
        let canApply = used > 0 && pct > 0 && pct <= 100
        HStack(spacing: 8) {
            Text(recalLabel(kind)).font(.system(size: 12)).frame(width: 92, alignment: .leading)
            Button { adjustPct(kind, by: -5) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).accessibilityLabel(String(localized: "Decrease by 5 percent"))
            Text("\(pct)%").font(.system(size: 12).monospacedDigit()).frame(minWidth: 36, alignment: .center)
            Button { adjustPct(kind, by: 5) } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.plain).accessibilityLabel(String(localized: "Increase by 5 percent"))
            Spacer(minLength: 0)
            Button { applyRecalibration(kind: kind) } label: {
                Text("Apply").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(canApply ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain).disabled(!canApply)
        }
    }

    private func recalLabel(_ kind: WindowKind) -> String {
        switch kind {
        case .session5h:    return String(localized: "Session 5h")
        case .weeklyAll:    return String(localized: "Weekly all")
        case .weeklySonnet: return String(localized: "Weekly Sonnet")
        }
    }

    private func adjustPct(_ kind: WindowKind, by delta: Int) {
        let current = recalPct[kind] ?? 50
        recalPct[kind] = min(100, max(1, current + delta))
    }

    private func window(for kind: WindowKind) -> UsageSnapshot.Window? {
        switch kind {
        case .session5h:    return appState.snapshot.session5h
        case .weeklyAll:    return appState.snapshot.weeklyAll
        case .weeklySonnet: return appState.snapshot.weeklySonnet
        }
    }

    private func applyRecalibration(kind: WindowKind) {
        guard let used = window(for: kind)?.usedTokens, used > 0,
              let pct = recalPct[kind], pct > 0 else { return }
        // newCap = used / (pct / 100) using integer math, rounded to nearest 1k.
        let newCap = max(1, (used * 100) / pct)
        let rounded = ((newCap + 500) / 1000) * 1000
        save(kind: kind, capTokens: rounded)
    }

    private func formatTokens(_ n: Int) -> String {
        if n == 0 { return "—" }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private func loadCurrent() async {
        guard let url = try? DatabaseManager.databaseURL(),
              let pool = try? DatabasePool(path: url.path) else { return }
        let loaded: [WindowKind: Int] = (try? await Task.detached {
            try pool.read { db in
                var result: [WindowKind: Int] = [:]
                for kind in WindowKind.allCases {
                    result[kind] = try DatabaseQueries.calibration(in: db, kind: kind)?.capTokens ?? 0
                }
                return result
            }
        }.value) ?? [:]
        await MainActor.run { caps = loaded }
    }

    private func save(kind: WindowKind, capTokens: Int) {
        guard let url = try? DatabaseManager.databaseURL(),
              let pool = try? DatabasePool(path: url.path) else { return }
        try? pool.write { db in
            try CalibrationEngine.setManual(in: db, kind: kind, capTokens: capTokens)
        }
        caps[kind] = capTokens
        appState.refresh()
    }

    private func resetAll() {
        guard let url = try? DatabaseManager.databaseURL(),
              let pool = try? DatabasePool(path: url.path) else { return }
        try? pool.write { db in
            for kind in WindowKind.allCases {
                try CalibrationEngine.reset(in: db, kind: kind)
            }
        }
        for kind in WindowKind.allCases { caps[kind] = 0 }
        appState.refresh()
    }
}

private struct InlineHooksPane: View {
    @State private var status = HookStatusService.currentStatus()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader(label: "Hooks", desc: "Shell integration status")
            hookRow("session-start router",
                    "Routes new sessions through Throttle.",
                    ok: status.sessionStartRouterInstalled)
            SettingsHair()
            hookRow("pre-compact",
                    "Snapshots usage before context compaction.",
                    ok: status.preCompactExtractorInstalled)
            SettingsHair()
            if status.killSwitchSet {
                hookRow("kill-switch",
                        "Active — CLAUDE_DISABLE_TOKOPT_HOOKS=1 is set; hooks are bypassed.",
                        ok: false, tag: "active", tagColor: .orange)
            } else {
                hookRow("kill-switch",
                        "Halts runs at your hard cap when set.",
                        ok: false, tag: "off")
            }
            SettingsNote(text: "Hooks are managed by the Claude Code CLI — Throttle reads their status, never edits your shell. To disable, run: export CLAUDE_DISABLE_TOKOPT_HOOKS=1")
        }
        .task {
            while !Task.isCancelled {
                status = HookStatusService.currentStatus()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func hookRow(_ name: String, _ desc: String, ok: Bool,
                         tag: String? = nil, tagColor: Color = .secondary) -> some View {
        HStack(spacing: 11) {
            Image(systemName: ok ? "checkmark.circle.fill" : "minus.circle")
                .font(.system(size: 14)).foregroundStyle(ok ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13))
                Text(desc).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(tag ?? (ok ? "detected" : "not installed"))
                .font(.system(size: 10, weight: .semibold).monospaced())
                .foregroundStyle(ok ? Color.green : tagColor)
        }
        .padding(.horizontal, 16).padding(.vertical, 9).frame(minHeight: 44)
    }
}

private struct InlineAboutPane: View {
    @State private var exportStatus: String = ""
    @State private var csvStatus: String = ""
    @State private var versionTapCount: Int = 0
    @State private var lastTapAt: Date = .distantPast
    @State private var showDevUnlockSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader(label: "Privacy")
            SettingsRow(title: "Reveal log file",
                        sub: "~/Library/Logs/Throttle — app behaviour only, no session content.") {
                SettingsButton(title: "Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppLogger.logFileURL])
                }
            }
            SettingsHair()
            SettingsRow(title: "Export diagnostics",
                        sub: exportStatus.isEmpty ? "Anonymized stats .zip to Desktop — token totals only." : exportStatus) {
                SettingsButton(title: "Export") {
                    exportStatus = String(localized: "Building…")
                    Task { @MainActor in
                        if let url = await runDiagnosticsExport() {
                            exportStatus = "Saved: \(url.lastPathComponent)"
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else { exportStatus = String(localized: "Failed — see log.") }
                    }
                }
            }
            SettingsHair()
            SettingsRow(title: "Export usage CSV",
                        sub: csvStatus.isEmpty ? "Full event history to Desktop — no message content." : csvStatus) {
                SettingsButton(title: "Export") {
                    csvStatus = String(localized: "Building…")
                    Task { @MainActor in
                        if let url = await runCSVExport() {
                            csvStatus = "Saved: \(url.lastPathComponent)"
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else { csvStatus = String(localized: "Failed — see log.") }
                    }
                }
            }
            SettingsNote(text: "Throttle collects no telemetry. Future opt-ins will appear here.")
            SettingsHair()
            linkRow("Privacy policy", url: "https://lorislab.fr/throttle/privacy")

            SettingsHair()
            aboutBlock
            SettingsHair()
            linkRow("Support", url: "mailto:support@lorislab.fr")
            SettingsHair()
            linkRow("Open-source meter on GitHub", url: "https://github.com/lorislabapp/throttle-meter")
            SettingsHair()
            linkRow("EULA", url: "https://lorislab.fr/throttle/eula")
        }
        .sheet(isPresented: $showDevUnlockSheet) { DevUnlockSheet() }
    }

    private var aboutBlock: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.12)],
                                         startPoint: .top, endPoint: .bottom))
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(.system(size: 24)).foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Throttle").font(.system(size: 14, weight: .semibold))
                Text("Version \(version)")
                    .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture { handleVersionTap() }
            }
            Spacer(minLength: 0)
            SettingsButton(title: "Check for updates") { UpdaterService.shared.checkForUpdates() }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private func linkRow(_ title: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        } label: {
            HStack {
                Text(title).font(.system(size: 13)).foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 11).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func handleVersionTap() {
        let now = Date()
        if now.timeIntervalSince(lastTapAt) > 3 { versionTapCount = 0 }
        lastTapAt = now
        versionTapCount += 1
        if versionTapCount >= 10 { versionTapCount = 0; showDevUnlockSheet = true }
    }

    @MainActor
    private func runDiagnosticsExport() async -> URL? {
        guard let url = try? DatabaseManager.databaseURL(),
              let pool = try? DatabasePool(path: url.path) else { return nil }
        return DiagnosticsExporter.exportToDesktop(database: pool)
    }

    @MainActor
    private func runCSVExport() async -> URL? {
        guard let url = try? DatabaseManager.databaseURL(),
              let pool = try? DatabasePool(path: url.path) else { return nil }
        return CSVExporter.exportToDesktop(database: pool)
    }
}

/// Minimal sheet for entering the developer-unlock key. Shown only after
/// 10 consecutive taps (within 3 s of each other) on the version label
/// in About. Submits the key to `DevUnlockService.attemptUnlock(key:)`,
/// which compares against a salted SHA-256 stored as a constant in the
/// binary. On success, Pro is unlocked permanently on this Mac and the
/// sheet dismisses.
private struct DevUnlockSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key: String = ""
    @State private var status: String = ""
    @State private var isError: Bool = false
    @FocusState private var keyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "key.horizontal.fill")
                    .foregroundStyle(.tint)
                Text("Developer unlock")
                    .font(.headline)
            }
            Text("Paste the dev key to unlock Pro permanently on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("Unlock key", text: $key)
                .textFieldStyle(.roundedBorder)
                .focused($keyFocused)
                .onSubmit { tryUnlock() }
            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .green)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Unlock") { tryUnlock() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { keyFocused = true }
    }

    private func tryUnlock() {
        let ok = DevUnlockService.shared.attemptUnlock(key: key)
        if ok {
            status = String(localized: "Pro unlocked on this Mac. Closing…")
            isError = false
            // Give the success message a beat to land, then dismiss
            // and refresh AppState so the menu-bar UI re-renders with
            // the new Pro state.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                dismiss()
                NotificationCenter.default.post(name: .devUnlockChanged, object: nil)
            }
        } else {
            status = String(localized: "Wrong key.")
            isError = true
            key = ""
        }
    }
}

extension Notification.Name {
    static let devUnlockChanged = Notification.Name("com.lorislab.throttle.dev-unlock-changed")
}

// MARK: - Sparkline

/// Tiny line+area chart for arrays of non-negative values. Implemented
/// with `Shape` (Core Animation) instead of `Canvas` (Metal/RenderBox),
/// because Canvas inside MenuBarExtra `.window` style crashes the
/// dropdown on macOS 26.5 — the regression that took down 2.0/2.1.
/// Path-based shapes go through CGContext, not the Metal pipeline,
/// and survive the regression. All-zero arrays render an empty flat
/// baseline rather than a divide-by-zero crash.
struct Sparkline: View {
    let values: [Int]
    let stroke: Color
    let fill: Color

    var body: some View {
        ZStack {
            SparklineArea(values: values).fill(fill)
            SparklineLine(values: values).stroke(
                stroke,
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
        }
        .accessibilityHidden(true)
    }
}

private struct SparklineArea: Shape {
    let values: [Int]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count >= 2 else { return p }
        let pts = sparklinePoints(values: values, in: rect)
        p.move(to: CGPoint(x: 0, y: rect.height))
        for c in pts { p.addLine(to: c) }
        p.addLine(to: CGPoint(x: rect.width, y: rect.height))
        p.closeSubpath()
        return p
    }
}

private struct SparklineLine: Shape {
    let values: [Int]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count >= 2 else { return p }
        let pts = sparklinePoints(values: values, in: rect)
        p.move(to: pts[0])
        for c in pts.dropFirst() { p.addLine(to: c) }
        return p
    }
}

private func sparklinePoints(values: [Int], in rect: CGRect) -> [CGPoint] {
    let maxV = max(values.max() ?? 0, 1)
    let stepX = rect.width / CGFloat(values.count - 1)
    return values.enumerated().map { i, v in
        let x = CGFloat(i) * stepX
        let y = rect.height - (CGFloat(v) / CGFloat(maxV)) * rect.height
        return CGPoint(x: x, y: y)
    }
}

// MARK: - InlineAssistantPane

private struct InlineAssistantPane: View {
    @Environment(AppState.self) private var appState
    @AppStorage("cavemanModeEnabled") private var cavemanModeEnabled = false
    @State private var importStatus: String = ""
    @State private var importing: Bool = false
    @State private var aiAvailability: [AIProviderKind: Bool] = [:]
    @State private var aiSelection: AIProviderKind? = AIProviderRegistry.shared.preferredKind
    @State private var aiKeyDraft: String = ""
    @State private var aiKeyStatus: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader(label: "AI Assistant", desc: "Powers the Project window's chat")
            SettingsRow(title: "Provider", sub: "Who answers \u{201C}why am I burning tokens?\u{201D}") {
                Picker("", selection: Binding(
                    get: { aiSelection ?? defaultProviderKind() },
                    set: { newValue in aiSelection = newValue; AIProviderRegistry.shared.preferredKind = newValue }
                )) {
                    Text("Apple").tag(AIProviderKind.appleIntelligence as AIProviderKind?)
                    Text("Claude").tag(AIProviderKind.claudeWebSession as AIProviderKind?)
                    Text("API").tag(AIProviderKind.claudeAPIKey as AIProviderKind?)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if (aiSelection ?? defaultProviderKind()) == .claudeAPIKey {
                SettingsHair()
                apiKeyRow
            }
            SettingsHair()
            SettingsRow(title: "Caveman mode", sub: "Terse, telegraphic replies from the project Assistant. Ug.") {
                Toggle("", isOn: $cavemanModeEnabled).labelsHidden().toggleStyle(.switch).tint(.accentColor)
            }
            SettingsHair()
            SettingsRow(title: "Import ccusage data",
                        sub: importStatus.isEmpty ? "Pull usage history from the ccusage CLI." : importStatus) {
                SettingsButton(title: importing ? "Importing…" : "Import") { runImport() }
            }
        }
        .onAppear { Task { await reloadAvailability() } }
    }

    private var apiKeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SecureField("sk-ant-…", text: $aiKeyDraft)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12).monospaced())
                SettingsButton(title: "Save") {
                    if ClaudeAPIKeyStore.write(aiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        aiKeyStatus = String(localized: "Key saved."); aiKeyDraft = ""
                        Task { await reloadAvailability() }
                    } else {
                        aiKeyStatus = String(localized: "Save failed — keychain access denied?")
                    }
                }
                if ClaudeAPIKeyStore.read() != nil {
                    SettingsButton(title: "Remove", role: .destructive) {
                        _ = ClaudeAPIKeyStore.delete(); aiKeyStatus = String(localized: "Key removed.")
                        Task { await reloadAvailability() }
                    }
                }
            }
            Text(aiKeyStatus.isEmpty ? "Stored in macOS Keychain. Billed by Anthropic on this key." : aiKeyStatus)
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private func defaultProviderKind() -> AIProviderKind {
        if aiAvailability[.appleIntelligence] == true { return .appleIntelligence }
        if aiAvailability[.claudeAPIKey] == true { return .claudeAPIKey }
        return .appleIntelligence
    }

    private func reloadAvailability() async {
        let map = await AIProviderRegistry.shared.availabilityMap()
        await MainActor.run { aiAvailability = map }
    }

    private func runImport() {
        Task {
            importing = true
            importStatus = ""
            do {
                let importer = CcusageImporter(database: appState.database)
                let days = try await importer.importFromCcusage()
                await MainActor.run {
                    appState.refresh()
                    importStatus = "✓ Imported \(days) days of usage data"
                    importing = false
                }
            } catch {
                await MainActor.run {
                    importStatus = "⚠️ Import failed: \(error.localizedDescription)"
                    importing = false
                }
            }
        }
    }
}
