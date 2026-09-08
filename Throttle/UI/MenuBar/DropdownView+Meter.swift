import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

extension DropdownView {
    // MARK: - Meter mode

    var meterContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            hairline
            exactModeWarningBanner.padding(.horizontal, 16)
            if !appState.claudeCodeDetected && !appState.codexDetected {
                emptyState(message: "Claude Code and Codex were not detected.")
            } else if !appState.snapshot.hasAnyData && appState.codexUsageSnapshot == nil {
                emptyState(message: "No usage events yet — start a Claude Code or Codex session.")
            } else {
                providerMeterReadout
            }
            if !appState.isPro && appState.snapshot.hasAnyData && !ProUpsellBanner.isSuppressed {
                ProUpsellBanner()
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
                appState.refreshCodexUsage()
                embeddedSignedIn = await EmbeddedClaudeSession.shared.isSignedIn()
            }
        }
    }

    @ViewBuilder
    var providerMeterReadout: some View {
        if appState.snapshot.hasAnyData {
            providerHeading("CLAUDE")
            meterReadout
        }
        if appState.codexDetected || appState.codexUsageSnapshot != nil {
            if appState.snapshot.hasAnyData { hairline }
            codexMeterReadout
        }
    }

    func providerHeading(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 11)
    }

    @ViewBuilder
    var codexMeterReadout: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Label("CODEX", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.7)
                Spacer(minLength: 0)
                if let snapshot = appState.codexUsageSnapshot {
                    Text(snapshot.isFresh() ? "LOCAL · FRESH" : "LOCAL · STALE")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(snapshot.isFresh() ? Color.secondary : Color.orange)
                }
            }

            if let snapshot = appState.codexUsageSnapshot {
                ForEach(snapshot.windows) { window in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(codexWindowLabel(window))
                                .font(.system(size: 12.5, weight: .semibold))
                            Spacer(minLength: 0)
                            Text("\(Int(window.usedPercent.rounded()))%")
                                .font(.system(size: 18, weight: .medium).monospacedDigit())
                                .foregroundStyle(snapshot.isFresh() ? .primary : .secondary)
                        }
                        UsageBar(
                            pct: window.normalizedUsed,
                            tint: progressTint(for: window.normalizedUsed),
                            degraded: !snapshot.isFresh(),
                            height: 6
                        )
                        HStack {
                            if let reset = window.resetsAt {
                                Text("resets in \(MultiCockpitModel.countdown(max(0, Int64(reset.timeIntervalSinceNow))))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Text(window.kind == .primary ? "primary" : "secondary")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                if let tokens = snapshot.tokens {
                    HStack {
                        Text("Current Codex session")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text("\(formatTokens(tokens.total)) tokens")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                    }
                }
            } else {
                Text("No local Codex usage event yet. Run a Codex turn, then reopen this menu.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    func codexWindowLabel(_ window: CodexUsageSnapshot.RateWindow) -> String {
        guard let minutes = window.windowMinutes else {
            return window.kind == .primary ? String(localized: "Primary limit") : String(localized: "Secondary limit")
        }
        if minutes == 300 { return String(localized: "5-hour limit") }
        if minutes == 10_080 { return String(localized: "Weekly limit") }
        if minutes.isMultiple(of: 1_440) { return "\(minutes / 1_440)-day limit" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60)-hour limit" }
        return "\(minutes)-minute limit"
    }

    /// Quiet one-line savings summary. Demoted from the old green hero card:
    /// savings answers "did this pay for itself", not "should I stop now" —
    /// so it sits as a footnote under the actions, never competing with the
    /// usage meter, which is the reason you open Throttle. The milestone
    /// celebration + badges are retired from the dropdown; the lifetime
    /// counter keeps accruing via meterContent's onAppear and can resurface
    /// in Stats.
    var savingsFootnote: some View {
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

    func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }

    /// Total EUR saved (lifetime + this week) using MilestoneTracker's conversion rate.
    var lifetimeAndWeeklyEUR: Double {
        let liveTokens = MilestoneTracker.shared.lifetimeTokens + appState.savedTokensThisWeek
        return MilestoneTracker.shared.eurFor(tokens: liveTokens)
    }

    /// Banner shown when the user has enabled exact mode but the latest poll
    /// failed — so the meter is silently falling back to local-JSONL estimates.
    /// Without this, the user sees plausible-looking numbers that can be wildly
    /// off from claude.ai's actual session % (the bug that prompted this banner).
    /// Auto-clears on the next successful poll because `onSnapshot` resets
    /// `exactModeError` to nil in AppDelegate.
    @ViewBuilder
    var exactModeWarningBanner: some View {
        if appState.exactModeEnabled, let err = appState.exactModeError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Exact mode unavailable — showing local estimates")
                        .font(.caption.weight(.semibold))
                    Text(describeExactModeError(err))
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

    struct ExactModeAction {
        let title: String
        let handler: () -> Void
    }

    /// Contextual one-tap remediation per error kind. Returns nil for cases
    /// where there's no obvious user action (none currently — every error has
    /// a remediation, but kept optional for forward-compat).
    func exactModeWarningAction(_ err: ExactModeError) -> ExactModeAction? {
        // With the embedded WKWebView session, almost every failure boils
        // down to "you're not actually authenticated" — stale cookie,
        // expired session, never signed in, claude.ai forced re-auth.
        // The right CTA is almost always "Sign in to claude.ai" which
        // opens our embedded sign-in window. Only pure transient HTTP
        // 5xx / timeout / parse errors get a Retry button.
        switch err {
        case .notSignedIn, .invalidResponse:
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
        case .httpError, .session, .timeout:
            return ExactModeAction(title: String(localized: "Retry")) {
                Task { await ExactModeService.shared.refresh() }
            }
        }
    }

    /// Identity + status. The binding hero owns the number, so no top-right %.
    /// EXACT is an inverted solid pill with a dot; PRO a soft pill; FREE outlined.
}
