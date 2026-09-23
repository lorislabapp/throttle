import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        // Counted here, inside the pass being measured: a runaway is a render
        // RATE, and no observer outside the view can see it.
        // `let _ =` on purpose: inside a @ViewBuilder this is a declaration and
        // contributes no view, while a bare `_ =` is an expression the builder
        // tries to turn into one. SwiftLint's redundant_discardable_let
        // autocorrect made that change and broke the build.
        // swiftlint:disable:next redundant_discardable_let
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
                // No `TimelineView` here, and that is the point. It was the only
                // self-scheduling component in this view, and this view is an
                // `NSStatusItem` button: every render calls `setImage:`, which
                // calls `_adjustLength`, which runs a full AutoLayout pass on the
                // status item window. A component that schedules its own next
                // update inside that cycle has no reason to stop, and on
                // 2026-08-21 it did not — 1029 of 1062 main-thread samples sat in
                // exactly that chain while the Mac was unusable.
                //
                // The countdown needs minute granularity. `appState.refresh()`
                // already fires whenever usage changes, which is far more often
                // than that, so the label ticks without asking SwiftUI to wake
                // itself up. This restores the rule stated above: every value
                // comes from state refreshed on a timer, never from a scheduler
                // living inside the render pass.
                gauge(text(pressure: Self.countdown(to: reset, now: Date())),
                      symbol: waiting ? "bell.badge.fill" : "hourglass", pct: pct)
            } else {
                gauge(text(pressure: "\(Int(pct * 100))%"),
                      symbol: waiting ? "bell.badge.fill" : meterIcon(for: pct), pct: pct)
            }
        } else {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
        }
    }

    /// The gauge label, with background work drawn as a 1 pt hairline under the
    /// icon (design 1a: no new glyph, the % stays the only number). Reads two
    /// STORED values on `BackgroundWork`, both quantised, so a whole pass changes
    /// the status item's image at most `BackgroundWork.menuBarSteps` times.
    @ViewBuilder
    private func gauge(_ title: String, symbol: String, pct: Double) -> some View {
        let work = BackgroundWork.shared
        if let mark = work.menuBarMark, let glyph = MenuBarWorkGlyph.image(symbol: symbol, mark: mark) {
            Label { Text(title) } icon: { Image(nsImage: glyph) }
                .labelStyle(.titleAndIcon)
                .accessibilityLabel(String(localized: "Throttle, \(Int(pct * 100)) percent used.")
                                    + (work.accessibilitySentence.map { " " + $0 } ?? ""))
        } else {
            Label(title, systemImage: symbol).labelStyle(.titleAndIcon)
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

    /// Delegates to `UsagePressure` — the same function the statusline uses.
    /// The two used to compute this separately and disagreed about whether the
    /// per-model weekly cap counts (it does not: exhausting it forces a model
    /// fallback, it does not lock you out).
    private func highestPressurePercent() -> Double? {
        UsagePressure.binding(snapshot: appState.snapshot,
                              exact: appState.exactSnapshot,
                              codex: appState.codexUsageSnapshot)?.fraction
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

/// Draws the gauge symbol with the background-work mark under it into one
/// template image (a status item renders its label as an image; an overlay view
/// would be dropped). Cached per symbol + mark: at most a handful ever exist.
@MainActor
enum MenuBarWorkGlyph {
    private static var cache: [String: NSImage] = [:]

    static func image(symbol: String, mark: BackgroundWork.MenuBarMark) -> NSImage? {
        let key = "\(symbol)|\(mark)"
        if let hit = cache[key] { return hit }
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) else { return nil }
        let warn: NSImage? = mark == .failed
            ? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
            : nil
        let gap: CGFloat = 1.5
        let width = base.size.width + (warn.map { $0.size.width + 2 } ?? 0)
        let height = base.size.height + gap + 1
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            base.draw(in: NSRect(x: 0, y: gap + 1, width: base.size.width, height: base.size.height))
            let lineW = base.size.width
            switch mark {
            case .progress(let step):
                NSColor.black.withAlphaComponent(0.18).setFill()
                NSRect(x: 0, y: 0, width: lineW, height: 1).fill()
                NSColor.black.withAlphaComponent(0.85).setFill()
                let filled = CGFloat(step) / CGFloat(BackgroundWork.menuBarSteps)
                NSRect(x: 0, y: 0, width: (lineW * filled).rounded(), height: 1).fill()
            case .quiet:
                NSColor.black.withAlphaComponent(0.5).setFill()
                var dot: CGFloat = 0
                while dot < lineW { NSRect(x: dot, y: 0, width: 1, height: 1).fill(); dot += 2 }
            case .failed:
                if let warn {
                    warn.draw(in: NSRect(x: base.size.width + 2, y: gap + 1,
                                         width: warn.size.width, height: warn.size.height))
                }
            }
            return true
        }
        image.isTemplate = true   // the menu bar tints it for light / dark
        cache[key] = image
        return image
    }
}
