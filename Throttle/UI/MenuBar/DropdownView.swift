import AppKit
import GRDB
import SwiftUI

struct DropdownView: View {
    @Environment(AppState.self) private var appState

    enum Mode {
        case meter
        case settings(SettingsTab)
        case stats
        case about
    }

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case calibration = "Calibration"
        case hooks = "Hooks"
        case privacy = "Privacy"

        var localizedTitle: String {
            switch self {
            case .general:     return String(localized: "General")
            case .calibration: return String(localized: "Calibration")
            case .hooks:       return String(localized: "Hooks")
            case .privacy:     return String(localized: "Privacy")
            }
        }
    }

    @State private var mode: Mode = .meter
    @State private var savingsLeafPulse: Bool = false

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
                case .about:
                    AboutInline(onBack: { mode = .settings(.general) })
                }
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    // MARK: - Meter mode

    private var meterContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !appState.claudeCodeDetected {
                emptyState(message: "Claude Code not detected. Install it to start measuring.")
            } else if !appState.snapshot.hasAnyData {
                emptyState(message: "No sessions yet — start one in Claude Code.")
            } else {
                windowsList
            }
            exactModeWarningBanner
            if appState.savedTokensThisWeek > 0 {
                savingsBanner
            }
            Divider().padding(.vertical, 4)
            proSection
            Divider().padding(.vertical, 4)
            footer
        }
    }

    /// Hero card showing tokens saved by the token-opt hooks this week.
    /// Token-opt is the headline value-add of Throttle, so this gets prime
    /// real estate instead of a tiny footer line. White text on a deep
    /// green background — high contrast against the dropdown's frosted
    /// background, so the number is unmissable.
    ///
    /// "Dynamic" combo: the leaf pulses for 1.5s when the weekly counter
    /// ticks up (concrete feedback that a hook just fired), a sparkline
    /// of the last 7 days lives next to the number so the figure feels
    /// alive even when nothing fired in the last hour, and a today-delta
    /// strip below makes "the counter is stale" impossible to confuse
    /// with "you didn't use Claude today" — they read different.
    private var savingsBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .scaleEffect(savingsLeafPulse ? 1.18 : 1.0)
                .shadow(color: .white.opacity(savingsLeafPulse ? 0.6 : 0), radius: 8)
                .animation(.spring(response: 0.4, dampingFraction: 0.5), value: savingsLeafPulse)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(formatTokens(appState.savedTokensThisWeek))
                        .font(.system(size: 28, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(value: Double(appState.savedTokensThisWeek)))
                        .animation(.smooth(duration: 0.6), value: appState.savedTokensThisWeek)
                    Text("tokens saved")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
                Text(todayDeltaCopy)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
            }
            Spacer(minLength: 0)
            Sparkline(values: appState.savedTokensByDay,
                      stroke: .white.opacity(0.95),
                      fill: .white.opacity(0.18))
                .frame(width: 64, height: 28)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.05, green: 0.45, blue: 0.27),
                            Color(red: 0.10, green: 0.62, blue: 0.39)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .padding(.top, 10)
        .onChange(of: appState.savedTokensThisWeek) { old, new in
            guard new > old else { return }
            savingsLeafPulse = true
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                await MainActor.run { savingsLeafPulse = false }
            }
        }
    }

    /// Copy below the big number — distinguishes "no save today (yet)"
    /// from "+5.2k today". Yesterday comparison only shown when both days
    /// are non-zero, otherwise the delta is meaningless noise.
    private var todayDeltaCopy: String {
        let today = appState.savedTokensToday
        let yesterday = appState.savedTokensYesterday
        if today == 0 {
            return String(localized: "This week — no save today yet")
        }
        if yesterday > 0 {
            let pct = Int((Double(today - yesterday) / Double(yesterday) * 100).rounded())
            let deltaSign = pct >= 0 ? "+" : ""
            return String(localized: "This week — +\(formatTokens(today)) today (\(deltaSign)\(pct)% vs yesterday)")
        }
        return String(localized: "This week — +\(formatTokens(today)) today")
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
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
        switch err {
        case .notSignedIn, .noClaudeTab, .safariNotRunning:
            return ExactModeAction(title: String(localized: "Open Safari")) {
                ExactModeService.shared.openSignInPage()
            }
        case .automationDenied:
            return ExactModeAction(title: String(localized: "Settings")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .httpError, .invalidResponse, .appleScript, .timeout:
            return ExactModeAction(title: String(localized: "Retry")) {
                Task { await ExactModeService.shared.refresh() }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Throttle")
                .font(.headline)
            if appState.isPro {
                Text("PRO")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
            }
            if appState.exactSnapshot?.isFresh() == true {
                Text("EXACT")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.15))
                    .foregroundStyle(Color.green)
                    .clipShape(Capsule())
            }
            Spacer()
            if let pct = displayedSession5hPercent() {
                Text("\(Int(pct * 100))%")
                    .font(.headline)
                    .foregroundStyle(headerColor(for: pct))
            }
        }
        .padding(.bottom, 6)
    }

    private func displayedSession5hPercent() -> Double? {
        if let ex = appState.exactSnapshot, ex.isFresh() {
            return Double(ex.fiveHour.utilization) / 100.0
        }
        return appState.snapshot.session5h.percentUsed
    }

    private func headerColor(for pct: Double) -> Color {
        switch pct {
        case ..<0.5:  return .secondary
        case ..<0.8:  return .primary
        case ..<0.95: return .orange
        default:      return .red
        }
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

    private var windowsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            metricRow(displayMetric(for: .session5h, title: String(localized: "Session (5h)")))
            metricRow(displayMetric(for: .weeklyAll, title: String(localized: "Weekly all models")))
            metricRow(displayMetric(for: .weeklySonnet, title: String(localized: "Weekly Sonnet only")))
        }
    }

    private struct DisplayMetric {
        let title: String
        let percent: Double?
        let resetInSeconds: Int64
        let isExact: Bool
    }

    private func displayMetric(for kind: WindowKind, title: String) -> DisplayMetric {
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
                title: title,
                percent: Double(ew.utilization) / 100.0,
                resetInSeconds: resetSec,
                isExact: true
            )
        }
        return DisplayMetric(
            title: title,
            percent: local.percentUsed,
            resetInSeconds: local.resetInSeconds,
            isExact: false
        )
    }

    @ViewBuilder
    private func metricRow(_ metric: DisplayMetric) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(metric.title).font(.subheadline)
                Spacer()
                if let pct = metric.percent {
                    Text("\(Int(pct * 100))% used")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("not calibrated")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
            if let pct = metric.percent {
                ProgressView(value: pct)
                    .progressViewStyle(.linear)
                    .tint(progressTint(for: pct))
            }
            if metric.resetInSeconds > 0 {
                Text("resets in \(formatDuration(metric.resetInSeconds)) (\(formatWallClock(metric.resetInSeconds)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        if isToday {
            f.setLocalizedDateFormatFromTemplate("ha")
            return f.string(from: target).lowercased()
        }
        if isTomorrow {
            f.setLocalizedDateFormatFromTemplate("ha")
            return "tmrw \(f.string(from: target).lowercased())"
        }
        if withinThreeDays {
            f.setLocalizedDateFormatFromTemplate("EEEha")
            return f.string(from: target).lowercased()
        }
        f.setLocalizedDateFormatFromTemplate("EEEMMMdha")
        return f.string(from: target).lowercased()
    }

    private func progressTint(for pct: Double) -> Color {
        switch pct {
        case ..<0.8:  return .accentColor
        case ..<0.95: return .orange
        default:      return .red
        }
    }

    private func formatDuration(_ seconds: Int64) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private var proSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: appState.isPro ? "checkmark.seal.fill" : "lock.fill")
                Text("Run Optimizer")
                Spacer()
                Text(appState.isPro ? "Pro ✓" : "Pro")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(appState.isPro ? .primary : .secondary)
            .contentShape(Rectangle())
            .onTapGesture {
                // Plan 2 wires the optimizer wizard here. For Plan 1 it's a no-op
                // even when Pro is unlocked — the wizard view doesn't exist yet.
            }
            HStack {
                Image(systemName: appState.isPro ? "checkmark.seal.fill" : "lock.fill")
                Text("Manage Hooks")
                Spacer()
                Text(appState.isPro ? "Pro ✓" : "Pro")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(appState.isPro ? .primary : .secondary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if let url = URL(string: "https://claude.ai/settings/usage") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Open claude.ai/usage", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.plain)

            Button {
                mode = .stats
            } label: {
                Label("Stats…", systemImage: "chart.line.uptrend.xyaxis")
            }
            .buttonStyle(.plain)

            Button {
                ProjectWindowController.shared.show(appState: appState)
            } label: {
                HStack {
                    Label("Project window", systemImage: "rectangle.split.3x1")
                    Spacer()
                    if !appState.isPro {
                        Text("PRO")
                            .font(.system(size: 9, weight: .heavy))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .buttonStyle(.plain)

            Button {
                mode = .settings(.general)
            } label: {
                Label("Settings…", systemImage: "gear")
            }
            .buttonStyle(.plain)

            Button {
                mode = .about
            } label: {
                Label("About Throttle", systemImage: "info.circle")
            }
            .buttonStyle(.plain)

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Throttle", systemImage: "power")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
    }

    // MARK: - Settings mode

    private func settingsContent(tab: SettingsTab) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    mode = .meter
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text("Settings").font(.headline)
                Spacer()
                Spacer().frame(width: 56) // balance the Back button width
            }

            Picker("", selection: Binding(
                get: { tab },
                set: { mode = .settings($0) }
            )) {
                ForEach(SettingsTab.allCases, id: \.self) { t in
                    Text(t.localizedTitle).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Divider()

            ScrollView {
                Group {
                    switch tab {
                    case .general:     InlineGeneralPane()
                    case .calibration: InlineCalibrationPane()
                    case .hooks:       InlineHooksPane()
                    case .privacy:     InlinePrivacyPane()
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 180, maxHeight: 320)
        }
    }
}

// MARK: - First-run inline view

private struct FirstRunInline: View {
    @Environment(AppState.self) private var appState

    enum PlanChoice: String, CaseIterable, Identifiable {
        case pro = "Pro"
        case max5x = "Max 5×"
        case max20x = "Max 20×"
        case skip = "Skip — auto-calibrate"

        var id: String { rawValue }
    }

    @State private var planChoice: PlanChoice = .skip
    @State private var enableLoginItems: Bool = false
    @State private var signedIn: Bool = false
    @State private var step: Int = 0

    private let totalSteps = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepIndicator
            Group {
                switch step {
                case 0: stepWelcome
                case 1: stepPlan
                default: stepFinish
                }
            }
            .frame(minHeight: 180, alignment: .top)
            stepNav
        }
        .task { await refreshSignedIn() }
    }

    private var stepIndicator: some View {
        HStack(spacing: 4) {
            ForEach(0..<totalSteps, id: \.self) { i in
                Capsule()
                    .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: i == step ? 18 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.2), value: step)
            }
            Spacer()
            Text("Step \(step + 1) of \(totalSteps)")
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
    }

    private var stepWelcome: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 36)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Throttle").font(.headline)
                    Text("The accurate Claude Code meter for your menu bar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Throttle reads `~/.claude/projects/` locally to compute your session-5h, weekly-all, and weekly-Sonnet usage. Nothing leaves your Mac unless you turn on Exact Mode (Pro) — and even then only Safari touches claude.ai, not Throttle directly.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepPlan: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pick your plan").font(.headline)
            Text("So we can pre-fill realistic caps. You can recalibrate exactly later.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Plan", selection: $planChoice) {
                ForEach(PlanChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.radioGroup).labelsHidden()
        }
    }

    private var stepFinish: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Almost done").font(.headline)
            Toggle("Launch Throttle at login", isOn: $enableLoginItems).font(.subheadline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Match claude.ai exactly (optional)").font(.subheadline.bold())
                Text("After first run: Settings → General → Exact mode → Test connection. Throttle drives your already-signed-in Safari to read claude.ai's true numbers.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Everything is configurable later in Settings.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var stepNav: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
                    .buttonStyle(.borderless)
            }
            Spacer()
            if step < totalSteps - 1 {
                Button("Next") { step += 1 }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Get Started") { apply() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func refreshSignedIn() async {
        // Safari Bridge mode: "signed in" = last successful poll exists.
        signedIn = ExactModeService.shared.hasFreshSnapshot
    }

    private func apply() {
        if enableLoginItems { try? LoginItemService.setEnabled(true) }
        let preset: [(WindowKind, Int)]? = {
            switch planChoice {
            case .pro:    return [(.session5h, 4_000_000), (.weeklyAll, 60_000_000), (.weeklySonnet, 60_000_000)]
            case .max5x:  return [(.session5h, 8_000_000), (.weeklyAll, 200_000_000), (.weeklySonnet, 200_000_000)]
            case .max20x: return [(.session5h, 20_000_000), (.weeklyAll, 800_000_000), (.weeklySonnet, 800_000_000)]
            case .skip:   return nil
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
        // If user signed in during first-run, kick off polling immediately.
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
    @State private var signedIn: Bool = false
    @State private var notificationsOn: Bool = ThresholdNotifier.shared.isEnabled
    @State private var calendarStatus: String = ""
    @State private var licenseKeyInput: String = ""
    @State private var licenseStatus: String = ""
    @State private var activating: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Startup").font(.subheadline.bold())
            Toggle("Launch Throttle at login", isOn: $loginItemsEnabled)
                .onChange(of: loginItemsEnabled) { _, new in
                    try? LoginItemService.setEnabled(new)
                }

            Divider()

            Text("Notifications").font(.subheadline.bold())
            Toggle("Notify when usage crosses 80% / 95%", isOn: $notificationsOn)
                .onChange(of: notificationsOn) { _, new in
                    ThresholdNotifier.shared.setEnabled(new)
                }
            Text("Triggers a banner on each window the first time it crosses each threshold (debounced 6h).")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add weekly reset reminder to Calendar") {
                Task {
                    let result = await CalendarReminderService.addNextWeeklyReset(
                        in: appState.snapshot,
                        exact: appState.exactSnapshot
                    )
                    await MainActor.run { handleCalendarResult(result) }
                }
            }
            .buttonStyle(.borderless).controlSize(.small)
            if !calendarStatus.isEmpty {
                Text(calendarStatus).font(.caption2).foregroundStyle(.tertiary)
            }

            Divider()

            licenseSection

            Divider()

            exactModeSection

            Divider()

            aiProviderSection

            Divider()
            HStack {
                Text("Updates").font(.subheadline.bold())
                Spacer()
                Text("Throttle \(currentVersionLabel)")
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            HStack {
                Button("Check for updates…") {
                    UpdaterService.shared.checkForUpdates()
                }
                .buttonStyle(.bordered).controlSize(.small)
                Spacer()
                if let last = UpdaterService.shared.lastCheckDate {
                    Text("Last checked \(formatRelative(last))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Text("Throttle auto-checks daily. Updates are signed and verified before install.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await refreshSignedIn() }
    }

    @State private var connectionStatus: String = ""
    @State private var testing: Bool = false

    private var licenseSection: some View {
        let trial = TrialService.shared
        let trialActive = trial.isActive && LicenseService.shared.currentKey == nil
        let trialExpired = trial.hasExpired && LicenseService.shared.currentKey == nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Throttle Pro").font(.subheadline.bold())
                Spacer()
                if let key = LicenseService.shared.currentKey {
                    Text("Activated").font(.caption2.bold()).foregroundStyle(.green)
                    Text(verbatim: "•").font(.caption2).foregroundStyle(.tertiary)
                    Text(key.prefix(13) + "…").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                } else if trialActive {
                    Text("Trial · \(trial.daysLeft)d left")
                        .font(.caption2.bold()).foregroundStyle(.blue)
                } else {
                    Text("Free").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if trialActive {
                trialBanner(daysLeft: trial.daysLeft, expired: false)
            } else if trialExpired {
                trialBanner(daysLeft: 0, expired: true)
            }
            if LicenseService.shared.currentKey == nil {
                // No license stored. Always show Paste so the user can activate a key
                // they received by email — even mid-trial, where appState.isPro is true
                // because of the trial flag (otherwise the Paste button gets hidden and
                // the email becomes unactionable).
                if !appState.isPro {
                    Text("Buy Throttle Pro for €19 (launch) — unlocks Stats Pro cards, exact mode, share badge, and more.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    if !appState.isPro {
                        Button("Buy Throttle Pro") {
                            if let url = URL(string: "https://lorislab.fr/throttle/buy") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    Button("Paste license key") {
                        activateFromClipboard()
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(activating)
                }
            } else {
                HStack(spacing: 6) {
                    if let exp = LicenseService.shared.expiresAt {
                        Text("Renews automatically. Expires \(exp.formatted(date: .abbreviated, time: .omitted)).")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Deactivate this Mac", role: .destructive) {
                        Task {
                            await LicenseService.shared.deactivate()
                            appState.refreshProStatus()
                            licenseStatus = "Deactivated."
                        }
                    }
                    .buttonStyle(.borderless).controlSize(.small)
                }
            }
            if !licenseStatus.isEmpty {
                Text(licenseStatus)
                    .font(.caption2)
                    .foregroundStyle(licenseStatus.hasPrefix("✓") ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func trialBanner(daysLeft: Int, expired: Bool) -> some View {
        let bg = expired ? Color.orange.opacity(0.10) : Color.blue.opacity(0.10)
        let border = expired ? Color.orange.opacity(0.30) : Color.blue.opacity(0.30)
        let title = expired
            ? "Trial ended — Pro features locked"
            : (daysLeft == 1 ? "Last day of Pro trial" : "Pro trial — \(daysLeft) days left")
        let subtitle = expired
            ? "Buy at €29 to keep Exact mode + Pro Stats."
            : "Buy at €19 launch price (ends with the trial)."
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: expired ? "lock.fill" : "hourglass")
                    .foregroundStyle(expired ? Color.orange : Color.blue)
                Text(title).font(.caption.bold())
                Spacer()
                Button("Buy now") {
                    if let url = URL(string: "https://buy.stripe.com/fZu14o7Hr0s0ant2nZds400") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            }
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(bg))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(border, lineWidth: 1))
    }

    private func activateFromClipboard() {
        guard let raw = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            licenseStatus = "Clipboard is empty. Copy the key from your purchase email first."
            return
        }
        guard raw.uppercased().hasPrefix("THROTTLE-") else {
            licenseStatus = "That doesn't look like a Throttle license key (should start with THROTTLE-)."
            return
        }
        activating = true
        licenseStatus = "Activating…"
        Task {
            let result = await LicenseService.shared.activate(key: raw.uppercased())
            await MainActor.run {
                activating = false
                switch result {
                case .success:
                    licenseStatus = "✓ Pro activated on this Mac."
                    appState.refreshProStatus()
                case .failure(let err):
                    licenseStatus = describeLicenseError(err)
                }
            }
        }
    }

    private func describeLicenseError(_ err: LicenseService.ActivationError) -> String {
        switch err {
        case .invalidKey:           return "Invalid license key."
        case .machineLimitReached:  return "Already activated on 3 Macs. Deactivate one first."
        case .revoked:              return "License revoked. Contact support@lorislab.fr."
        case .verificationFailed:   return "Server response failed signature check. Don't trust this network."
        case .network(let m):       return "Network error: \(m)"
        case .server(let code):     return "Server error \(code). Try again later."
        case .decode(let m):        return "Couldn't decode response: \(m)"
        }
    }

    private var exactModeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Exact mode").font(.subheadline.bold())
                Spacer()
                if appState.isPro {
                    Text("PRO ✓").font(.caption2.bold()).foregroundStyle(.green)
                } else {
                    Text("PRO").font(.caption2.bold()).foregroundStyle(.secondary)
                }
            }
            Text("Throttle asks your signed-in Safari to fetch your usage data. Safari handles the cookies and signing — we just read the result. Nothing leaves your Mac.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Enable exact mode", isOn: Binding(
                get: { appState.exactModeEnabled },
                set: { newValue in
                    appState.setExactModeEnabled(newValue)
                    if newValue {
                        ExactModeService.shared.start()
                    } else {
                        ExactModeService.shared.stop()
                        appState.exactSnapshot = nil
                    }
                }
            ))
            .disabled(!appState.isPro)

            VStack(alignment: .leading, spacing: 2) {
                Text("Setup (one-time):").font(.caption2.bold()).foregroundStyle(.secondary)
                Text("1. Click **Open claude.ai in Safari** below.\n2. Sign in if needed (skip if already signed in).\n3. Click **Test connection**. macOS will ask permission for Throttle to control Safari — Allow.\n4. Done — Throttle polls Safari every 5 minutes.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 4))

            HStack(spacing: 6) {
                Button("Open claude.ai in Safari") {
                    ExactModeService.shared.openSignInPage()
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(!appState.isPro)

                Button(testing ? "Testing…" : "Test connection") {
                    testConnection()
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(!appState.isPro || testing)
            }

            if !connectionStatus.isEmpty {
                Text(connectionStatus)
                    .font(.caption2)
                    .foregroundStyle(connectionStatus.hasPrefix("✓") ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let snap = appState.exactSnapshot {
                Text("Last poll: \(formatRelative(snap.fetchedAt))")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else if appState.exactModeEnabled {
                Text("Polling…")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if let err = appState.exactModeError {
                Text("Error: \(describe(err))")
                    .font(.caption2).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                    connectionStatus = "✓ Working. Exact numbers now showing above."
                    signedIn = true
                    if appState.exactModeEnabled {
                        ExactModeService.shared.start()
                    }
                case .failure(let err):
                    signedIn = false
                    connectionStatus = describe(err)
                }
            }
        }
    }

    private func refreshSignedIn() {
        // Safari Bridge mode: "signed in" = last successful poll exists.
        signedIn = ExactModeService.shared.hasFreshSnapshot
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

    // MARK: - AI provider

    @State private var aiAvailability: [AIProviderKind: Bool] = [:]
    @State private var aiKeyDraft: String = ""
    @State private var aiKeyStatus: String = ""
    @State private var aiSelection: AIProviderKind? = AIProviderRegistry.shared.preferredKind

    private var aiProviderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI assistant").font(.subheadline.bold())
            Text("Powers the Project window's Assistant tab. Pick which backend Throttle calls when you chat with the assistant about a project.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("", selection: Binding(
                get: { aiSelection ?? defaultProviderKind() },
                set: { newValue in
                    aiSelection = newValue
                    AIProviderRegistry.shared.preferredKind = newValue
                }
            )) {
                ForEach(AIProviderKind.allCases, id: \.self) { kind in
                    HStack(spacing: 4) {
                        Text(kindLabel(kind))
                        if aiAvailability[kind] == false {
                            Text("(unavailable)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tag(kind as AIProviderKind?)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if (aiSelection ?? defaultProviderKind()) == .claudeAPIKey {
                aiKeyField
            }
        }
        .onAppear { Task { await reloadAIAvailability() } }
    }

    private func kindLabel(_ kind: AIProviderKind) -> String {
        switch kind {
        case .appleIntelligence: return String(localized: "Apple Intelligence")
        case .claudeWebSession:  return String(localized: "Claude (subscription)")
        case .claudeAPIKey:      return String(localized: "API key")
        }
    }

    /// Default selection when the user hasn't picked one yet — favours
    /// Apple Intel if available, falls back to API key (the only other
    /// provider that's actually wired in v2.1).
    private func defaultProviderKind() -> AIProviderKind {
        if aiAvailability[.appleIntelligence] == true { return .appleIntelligence }
        if aiAvailability[.claudeAPIKey]      == true { return .claudeAPIKey }
        return .appleIntelligence
    }

    private var aiKeyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField("sk-ant-…", text: $aiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                Button("Save") {
                    if ClaudeAPIKeyStore.write(aiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        aiKeyStatus = String(localized: "Key saved.")
                        aiKeyDraft = ""
                        Task { await reloadAIAvailability() }
                    } else {
                        aiKeyStatus = String(localized: "Save failed — keychain access denied?")
                    }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(aiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if ClaudeAPIKeyStore.read() != nil {
                    Button("Remove") {
                        _ = ClaudeAPIKeyStore.delete()
                        aiKeyStatus = String(localized: "Key removed.")
                        Task { await reloadAIAvailability() }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
            Text("Stored in macOS Keychain. Cost is billed directly by Anthropic on this key.")
                .font(.caption2).foregroundStyle(.tertiary)
            if !aiKeyStatus.isEmpty {
                Text(aiKeyStatus).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func reloadAIAvailability() async {
        let map = await AIProviderRegistry.shared.availabilityMap()
        await MainActor.run { self.aiAvailability = map }
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
            ("4M (Pro)",   4_000_000),
            ("8M (Max 5×)", 8_000_000),
            ("20M (Max 20×)", 20_000_000)
        ],
        .weeklyAll: [
            ("60M (Pro)",   60_000_000),
            ("200M (Max 5×)", 200_000_000),
            ("800M (Max 20×)", 800_000_000)
        ],
        .weeklySonnet: [
            ("60M (Pro)",   60_000_000),
            ("200M (Max 5×)", 200_000_000),
            ("800M (Max 20×)", 800_000_000)
        ]
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Caps (tokens)").font(.subheadline.bold())
            row(.session5h,    String(localized: "Session (5h)"))
            row(.weeklyAll,    String(localized: "Weekly all models"))
            row(.weeklySonnet, String(localized: "Weekly Sonnet only"))

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Recalibrate from claude.ai")
                    .font(.subheadline.bold())
                Text("Open claude.ai, read the % shown for each limit, enter it here, then Apply. Throttle adjusts each cap so the meter matches.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            recalRow(.session5h,    String(localized: "Session (5h)"))
            recalRow(.weeklyAll,    String(localized: "Weekly all models"))
            recalRow(.weeklySonnet, String(localized: "Weekly Sonnet only"))

            Divider()
            Button("Reset all calibrations", role: .destructive) {
                resetAll()
            }
            .buttonStyle(.borderless)
            Text("Manual numeric entry returns in v1.1 — see release notes.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .task { await loadCurrent() }
    }

    @ViewBuilder
    private func recalRow(_ kind: WindowKind, _ label: String) -> some View {
        let used = window(for: kind)?.usedTokens ?? 0
        let pct = recalPct[kind] ?? 50
        let canApply = used > 0 && pct > 0 && pct <= 100
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.bold())
            HStack(spacing: 8) {
                Button { adjustPct(kind, by: -5) } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.none)

                Button { adjustPct(kind, by: -1) } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)

                Text("\(pct)%")
                    .font(.caption.monospaced())
                    .frame(minWidth: 36, alignment: .center)

                Button { adjustPct(kind, by: 1) } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)

                Button { adjustPct(kind, by: 5) } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)

                Spacer()

                Button("Apply") {
                    applyRecalibration(kind: kind)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canApply)
            }
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

    @ViewBuilder
    private func row(_ kind: WindowKind, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption.bold())
                Spacer()
                Text(formatTokens(caps[kind] ?? 0))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(Self.presets[kind] ?? [], id: \.tokens) { preset in
                    Button(preset.label) {
                        save(kind: kind, capTokens: preset.tokens)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
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
        VStack(alignment: .leading, spacing: 8) {
            row(String(localized: "SessionStart router"), ok: status.sessionStartRouterInstalled)
            row(String(localized: "PreCompact extractor"), ok: status.preCompactExtractorInstalled)
            if status.killSwitchSet {
                Text("⚠ Kill switch active — CLAUDE_DISABLE_TOKOPT_HOOKS=1 set in your shell")
                    .font(.caption).foregroundStyle(.orange)
            }
            Divider()
            Text("Hooks management UI ships in v1.1. To install, use the Optimizer wizard (Pro). To disable, run:")
                .font(.caption).foregroundStyle(.secondary)
            Text("export CLAUDE_DISABLE_TOKOPT_HOOKS=1")
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .task {
            while !Task.isCancelled {
                status = HookStatusService.currentStatus()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func row(_ label: String, ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? .green : .secondary)
            Text(label).font(.subheadline)
            Spacer()
            Text(ok ? "Active" : "Not installed")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct InlinePrivacyPane: View {
    @State private var exportStatus: String = ""
    @State private var csvStatus: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local logs").font(.subheadline.bold())
            Button("Reveal log file in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([AppLogger.logFileURL])
            }
            .buttonStyle(.borderless)
            Text("Logs include app behaviour only — no session content.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            Text("Diagnostics").font(.subheadline.bold())
            Text("Bundle anonymized stats (event counts, hook status, last error) into a .zip on your Desktop. No usage content, no model details — token totals only. For support requests.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Export diagnostics to Desktop") {
                exportStatus = "Building…"
                Task { @MainActor in
                    if let url = await runDiagnosticsExport() {
                        exportStatus = "Saved: \(url.lastPathComponent)"
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        exportStatus = "Failed — see log."
                    }
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
            if !exportStatus.isEmpty {
                Text(exportStatus).font(.caption2).foregroundStyle(.tertiary)
            }

            Divider()

            Text("Export usage history").font(.subheadline.bold())
            Text("Save the full event history as a CSV file on your Desktop — for pivot tables, custom dashboards, or moving data to another tool. Same privacy posture as diagnostics: token counts and project paths only, no message content.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Export CSV to Desktop") {
                csvStatus = String(localized: "Building…")
                Task { @MainActor in
                    if let url = await runCSVExport() {
                        csvStatus = String(localized: "Saved: \(url.lastPathComponent)")
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        csvStatus = String(localized: "Failed — see log.")
                    }
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
            if !csvStatus.isEmpty {
                Text(csvStatus).font(.caption2).foregroundStyle(.tertiary)
            }

            Divider()
            Text("Telemetry").font(.subheadline.bold())
            Text("Throttle does not collect telemetry. Future opt-ins will appear here.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Link("Privacy policy at lorislab.fr/throttle/privacy",
                 destination: URL(string: "https://lorislab.fr/throttle/privacy")!)
                .font(.caption)
        }
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

// MARK: - About inline

private struct AboutInline: View {
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { onBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                Text("About").font(.headline)
                Spacer()
                Spacer().frame(width: 56)
            }
            Divider()

            VStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("Throttle").font(.title2)
                Text("Version \(version)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Built by LorisLabs.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("github.com/lorislabapp/throttle-meter (open-source meter)",
                     destination: URL(string: "https://github.com/lorislabapp/throttle-meter")!)
                    .font(.caption)
                Link("EULA",
                     destination: URL(string: "https://lorislab.fr/throttle/eula")!)
                    .font(.caption)
                Link("Privacy",
                     destination: URL(string: "https://lorislab.fr/throttle/privacy")!)
                    .font(.caption)
            }
        }
    }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

// MARK: - Sparkline

/// Tiny line+area chart for arrays of non-negative values. Skips Charts to
/// keep the dropdown light and to render correctly on macOS 26.5 (Charts
/// went invisible there in early 2026). Shapes the line as a smooth path
/// so 7 daily points don't look jagged. All-zero arrays render an empty
/// flat baseline rather than a divide-by-zero crash.
struct Sparkline: View {
    let values: [Int]
    let stroke: Color
    let fill: Color

    var body: some View {
        Canvas { ctx, size in
            guard values.count >= 2 else { return }
            let maxV = max(values.max() ?? 0, 1)
            let stepX = size.width / CGFloat(values.count - 1)
            let pathPoints = values.enumerated().map { i, v -> CGPoint in
                let x = CGFloat(i) * stepX
                let y = size.height - (CGFloat(v) / CGFloat(maxV)) * size.height
                return CGPoint(x: x, y: y)
            }

            var area = Path()
            area.move(to: CGPoint(x: 0, y: size.height))
            for p in pathPoints { area.addLine(to: p) }
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .color(fill))

            var line = Path()
            line.move(to: pathPoints[0])
            for p in pathPoints.dropFirst() { line.addLine(to: p) }
            ctx.stroke(line, with: .color(stroke), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
