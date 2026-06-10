import SwiftUI

/// The cockpit window: the decision layer (Strip A) pinned above a real terminal
/// running `claude`. The terminal is just the container; the differentiator is the
/// instrument on top — the binding number + pressure + an at-cap warning — the
/// thing Anthropic's own usage dashboard does not surface.
///
/// Step 1 (this file): identity bar + Strip A (BindingHero + HeadroomBar +
/// AtLimitBanner) on **real data only**. Forecast nudge and per-session cost cells
/// are intentionally absent until their feeds are wired — per the spec's golden
/// rule, we never render a number we can't stand behind.
struct CockpitWindowRoot: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            identityBar
            hairline
            if let b = binding, b.pct >= 0.80 {
                atLimitBanner(b)
                hairline
            }
            stripA
            hairline
            CockpitTerminalView()
                .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var hairline: some View {
        Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
    }

    // MARK: - Identity bar (gauge · Throttle · pills)

    private var identityBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 14)).foregroundStyle(.primary.opacity(0.85))
            Text("Throttle Cockpit").font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            appState.isPro ? pill("PRO", solid: false) : pill("FREE", solid: false)
            if isExact { exactPill }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func pill(_ t: String, solid: Bool) -> some View {
        Text(t)
            .font(.system(size: 9, weight: .heavy)).tracking(0.06)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(.secondary)
    }

    private var exactPill: some View {
        HStack(spacing: 4) {
            Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 4, height: 4)
            Text("EXACT")
        }
        .font(.system(size: 9, weight: .heavy)).tracking(0.06)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.primary, in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Strip A (decision)

    private var stripA: some View {
        HStack(alignment: .center, spacing: 0) {
            bindingCell
            Spacer(minLength: 12)
            otherWindowsCluster
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }

    @ViewBuilder
    private var bindingCell: some View {
        if let b = binding {
            VStack(alignment: .leading, spacing: 7) {
                dlLabel("BINDING NOW")
                bindingHero(b)
                headroomBar(b.pct, degraded: b.degraded, width: 150)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                dlLabel("BINDING NOW")
                Text(verbatim: "—").font(.system(size: 30, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
        }
    }

    private func bindingHero(_ b: Reading) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            heroNumber(b)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(b.name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.primary)
                    Text(b.sub).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Text(b.resetText).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
    }

    private func heroNumber(_ b: Reading) -> some View {
        let color: Color = b.degraded ? .secondary : pressureColor(b.pct)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            if b.degraded {
                Text(verbatim: "≈").font(.system(size: 18, weight: .regular)).foregroundStyle(.secondary)
            }
            Text("\(Int((b.pct * 100).rounded()))")
                .font(.system(size: 30, weight: .medium).monospacedDigit()).tracking(-0.6)
            Text(verbatim: "%").font(.system(size: 15, weight: .regular)).opacity(0.55)
        }
        .foregroundStyle(color)
    }

    private var otherWindowsCluster: some View {
        HStack(spacing: 14) {
            ForEach(others, id: \.kind) { r in
                compactReadout(r)
            }
        }
    }

    private func compactReadout(_ r: Reading) -> some View {
        HStack(spacing: 6) {
            Text(r.shortLabel).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            Text("\(r.degraded ? "≈" : "")\(Int((r.pct * 100).rounded()))%")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(r.degraded ? Color.secondary : pressureColor(r.pct))
                .lineLimit(1)
            miniBar(r.pct, degraded: r.degraded)
        }
        .fixedSize()
    }

    // MARK: - At-limit banner

    private func atLimitBanner(_ b: Reading) -> some View {
        let crit = b.pct >= 0.95
        let tint: Color = crit ? .red : .orange
        let text = crit
            ? "\(b.name) \(b.sub) is over its cap — finish up or switch to Sonnet."
            : "Approaching the \(b.name) \(b.sub) cap — ease off or switch to Sonnet."
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13)).foregroundStyle(tint)
            Text(text).font(.system(size: 12.5)).foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10))
    }

    // MARK: - Small parts

    private func dlLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 9.5, weight: .bold)).tracking(0.8)
            .foregroundStyle(.tertiary)
    }

    private func headroomBar(_ pct: Double, degraded: Bool, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.10)).frame(width: width, height: 5)
            tick(at: 0.80, width: width)
            tick(at: 0.95, width: width)
            Capsule().fill(degraded ? Color.secondary : pressureColor(pct))
                .frame(width: max(3, width * min(1, pct)), height: 5)
        }
        .frame(width: width, height: 5)
    }

    private func tick(at frac: Double, width: CGFloat) -> some View {
        Rectangle().fill(Color.primary.opacity(0.22)).frame(width: 1, height: 5)
            .offset(x: width * frac)
    }

    private func miniBar(_ pct: Double, degraded: Bool) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.12)).frame(width: 44, height: 4)
            Capsule().fill(degraded ? Color.secondary : pressureColor(pct))
                .frame(width: max(3, 44 * min(1, pct)), height: 4)
        }
    }

    private func pressureColor(_ pct: Double) -> Color {
        switch pct {
        case ..<0.80: return Color.primary.opacity(0.55)
        case ..<0.95: return .orange
        default:      return .red
        }
    }

    // MARK: - Readings (exact when fresh, else local estimate)

    /// A resolved usage window for display: name/sub, percent, reset text, and
    /// whether the value is an estimate (local fallback) vs exact (server-true).
    private struct Reading {
        let kind: WindowKind
        let name: String
        let sub: String
        let shortLabel: String
        let pct: Double
        let resetText: String
        let degraded: Bool
    }

    private var isExact: Bool { appState.exactSnapshot?.isFresh() == true }

    private var readings: [Reading] {
        [
            reading(.session5h, name: "Session", sub: "5h", short: "5h",
                    local: appState.snapshot.session5h, exact: appState.exactSnapshot?.fiveHour),
            reading(.weeklyAll, name: "Weekly", sub: "all models", short: "7d",
                    local: appState.snapshot.weeklyAll, exact: appState.exactSnapshot?.sevenDay),
            reading(.weeklySonnet, name: "Weekly", sub: "Sonnet", short: "Son",
                    local: appState.snapshot.weeklySonnet, exact: appState.exactSnapshot?.sevenDaySonnet),
        ].compactMap { $0 }
    }

    /// The window closest to its cap — the number that decides keep-going-or-stop.
    private var binding: Reading? {
        readings.max { $0.pct < $1.pct }
    }

    private var others: [Reading] {
        guard let b = binding else { return readings }
        return readings.filter { $0.kind != b.kind }
    }

    private func reading(
        _ kind: WindowKind, name: String, sub: String, short: String,
        local: UsageSnapshot.Window, exact: ExactSnapshot.Window?
    ) -> Reading? {
        let degraded = !isExact
        let pct: Double?
        let resetSeconds: Int64
        if isExact, let exact {
            pct = Double(exact.utilization) / 100.0
            resetSeconds = exact.resetsAt.map { Int64(max(0, $0.timeIntervalSinceNow)) } ?? local.resetInSeconds
        } else {
            pct = local.percentUsed
            resetSeconds = local.resetInSeconds
        }
        guard let pct else { return nil }
        return Reading(
            kind: kind, name: name, sub: sub, shortLabel: short,
            pct: pct, resetText: "resets in \(formatReset(resetSeconds))", degraded: degraded
        )
    }

    private func formatReset(_ seconds: Int64) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }
}
