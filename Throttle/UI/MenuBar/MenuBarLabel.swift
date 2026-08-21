import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        // Counted here, inside the pass being measured: a runaway is a render
        // RATE, and no observer outside the view can see it.
        let _ = MenuBarUpdateGuard.noteRender()

        // A runaway update loop on this label swap-locked a 16 GB Mac (3.2.88).
        // Once the watchdog trips, render one static symbol: no Label, no
        // countdown, no width changes — nothing that can drive another
        // `NSStatusItem._adjustLength` AutoLayout pass. See `MenuBarUpdateGuard`.
        if MenuBarUpdateGuard.isDegraded {
            Image(systemName: "gauge.with.dots.needle.0percent")
        } else if !appState.claudeCodeDetected && !appState.codexDetected {
            Image(systemName: "gauge.with.dots.needle.0percent")
        } else if !appState.snapshot.hasAnyData && appState.codexUsageSnapshot == nil {
            Image(systemName: "gauge.with.dots.needle.0percent")
        } else if let pct = highestPressurePercent() {
            // Show the window closest to its limit — that's the one that
            // will actually throttle the user. Hiding a 100% weekly cap
            // behind a 0% session pill is misleading.
            // H07: a hidden session waiting on input swaps the gauge for a bell,
            // so "needs you" surfaces on the always-visible menu-bar item even
            // with the Cockpit closed / notifications off.
            //
            // At the cap the percentage stops being information — the only
            // question left is "when do I get it back". Swap in a live
            // countdown to the binding window's reset while it's saturated.
            // `MultiCockpitModel.waitingCount` is a STORED Int on purpose. Reading
            // a computed one here subscribed the menu bar to `needsInput` on every
            // open tab, which is what produced the runaway loop above.
            if pct >= 0.98, let reset = bindingResetDate() {
                TimelineView(.everyMinute) { context in
                    Label(text(pressure: Self.countdown(to: reset, now: context.date)),
                          systemImage: waiting ? "bell.badge.fill" : "hourglass")
                        .labelStyle(.titleAndIcon)
                }
            } else {
                Label(text(pressure: "\(Int(pct * 100))%"),
                      systemImage: waiting ? "bell.badge.fill" : meterIcon(for: pct))
                    .labelStyle(.titleAndIcon)
            }
        } else {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
        }
    }

    /// A session is blocked on a question. Reads the STORED count — see
    /// `MultiCockpitModel.waitingCount` for why this must never be computed.
    /// The bell is honoured only when the user left the signal on.
    private var waiting: Bool {
        MenuBarSignalSettings.shared.isOn(.waiting) && MultiCockpitModel.shared.waitingCount > 0
    }

    /// Cap pressure first, then whatever optional signals are switched on, in a
    /// fixed order. Every value here comes from state refreshed on a timer, never
    /// from a query run inside the render pass.
    private func text(pressure: String) -> String {
        var parts = [pressure]
        for signal in MenuBarSignal.renderOrder where MenuBarSignalSettings.shared.isOn(signal) {
            switch signal {
            case .waiting:
                continue   // rendered as the bell icon, not as text
            case .cost:
                let eur = appState.weeklyCostEUR
                if eur > 0 { parts.append(String(format: "%.2f€", eur)) }
            case .tokens:
                let tokens = appState.snapshot.weeklyAll.usedTokens
                if tokens > 0 { parts.append(Self.compactTokens(tokens)) }
            }
        }
        return parts.joined(separator: "  ")
    }

    /// Menu-bar width is scarce: 1.2M, 940k, 512. Never a raw seven-digit number.
    static func compactTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return "\(tokens / 1_000)k" }
        return "\(tokens)"
    }

    private func highestPressurePercent() -> Double? {
        // Only count caps that gate *all* usage: the 5h session and the
        // all-models weekly cap. The Sonnet-only weekly cap is deliberately
        // excluded — hitting it doesn't lock you out, it just forces a
        // fallback to Opus, so surfacing it as a 100% headline made users
        // think they were throttled when they still had headroom.
        //
        // Prefer exact-mode data when fresh — those are the numbers Anthropic
        // is actually rate-limiting against. Fall back to local rolling-window
        // math otherwise.
        var providerPressures: [Double] = []
        if let ex = appState.exactSnapshot, ex.isFresh() {
            let exactPcts = [
                Double(ex.fiveHour.utilization),
                Double(ex.sevenDay.utilization)
            ].max() ?? 0
            providerPressures.append(exactPcts / 100.0)
        } else {
            providerPressures.append(contentsOf: [
                appState.snapshot.session5h.percentUsed,
                appState.snapshot.weeklyAll.percentUsed
            ].compactMap { $0 })
        }
        if let codex = appState.codexUsageSnapshot, codex.isFresh(),
           let pressure = codex.highestPressure {
            providerPressures.append(pressure)
        }
        return providerPressures.max()
    }

    /// The reset moment of the most-binding saturated window, when known.
    /// Exact-mode resets come straight from Anthropic; Codex windows carry
    /// their own. Local rolling-window math has no authoritative reset — the
    /// label keeps showing the percentage in that case rather than guessing.
    private func bindingResetDate() -> Date? {
        var candidates: [(pressure: Double, reset: Date)] = []
        if let ex = appState.exactSnapshot, ex.isFresh() {
            for window in [ex.fiveHour, ex.sevenDay] where window.utilization >= 98 {
                if let reset = window.resetsAt {
                    candidates.append((Double(window.utilization) / 100.0, reset))
                }
            }
        }
        if let codex = appState.codexUsageSnapshot, codex.isFresh() {
            for window in codex.windows where window.normalizedUsed >= 0.98 {
                if let reset = window.resetsAt {
                    candidates.append((window.normalizedUsed, reset))
                }
            }
        }
        // Among saturated windows the user is freed when the SOONEST one
        // resets only if it is the binding one — pick the highest pressure,
        // break ties on the earlier reset.
        return candidates.max { a, b in
            a.pressure == b.pressure ? a.reset > b.reset : a.pressure < b.pressure
        }?.reset
    }

    /// Compact countdown for the menu bar: "47m", "2h05", "3d". Clamps at
    /// "now" once the reset has passed but a stale snapshot still says 100%.
    static func countdown(to reset: Date, now: Date) -> String {
        let seconds = max(0, Int(reset.timeIntervalSince(now)))
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return String(format: "%dh%02d", hours, minutes % 60) }
        return "\(hours / 24)d"
    }

    private func meterIcon(for percent: Double) -> String {
        switch percent {
        case ..<0.5:  return "gauge.with.dots.needle.bottom.50percent"
        case ..<0.8:  return "gauge.with.dots.needle.50percent"
        case ..<0.95: return "gauge.with.dots.needle.67percent"
        default:      return "gauge.with.dots.needle.100percent"
        }
    }
}
