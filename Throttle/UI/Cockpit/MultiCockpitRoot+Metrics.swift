import AppKit
import SwiftUI
import ThrottleShared

extension MultiCockpitRoot {

    /// Per-session question history — the "don't lose the question" feed.
    /// Shown whenever claude has asked anything this session (even after you've
    /// answered), collapsed to a count; tap to expand the full list with times.
    @ViewBuilder
    func questionFeed(_ s: CockpitTab) -> some View {
        let qs = s.questions
        if !qs.isEmpty {
            let open = expandedFeed == s.id
            Button { expandedFeed = open ? nil : s.id } label: {
                HStack(spacing: 4) {
                    Image(systemName: "questionmark.bubble").font(.system(size: 9))
                    Text("\(qs.count) question\(qs.count == 1 ? "" : "s")")
                        .font(.system(size: 9.5, weight: .medium))
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(.tertiary).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(qs.reversed()) { q in
                        HStack(alignment: .top, spacing: 6) {
                            Text(uptime(q.askedAt)).font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary).frame(width: 30, alignment: .trailing)
                            Text(q.text).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
                .padding(.leading, 2).padding(.top, 2)
            }
        }
    }

    /// "waiting" badge — claude is blocked on a question in this session. Orange
    /// is earned here: it's a real action-required state. Optional count for the
    /// header rollup.
    func waitingChip(_ count: Int = 0) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "bell.badge.fill").font(.system(size: 8.5, weight: .semibold))
            Text(count > 0 ? "\(count) waiting" : "waiting").font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Color.orange.opacity(0.12), in: Capsule())
    }

    /// One spoken label per rail row — surfaces the waiting/attention state that
    /// was conveyed only by an orange dot before (C03; the feature's differentiator).
    func railRowA11yLabel(_ s: CockpitTab) -> String {
        var parts = [s.projectName]
        if s.needsInput { parts.append("waiting for your input") }
        if s.isHibernated { parts.append("hibernated") }
        if let issue = s.resumeIssue { parts.append(issue) }
        if let reason = s.resourceReason { parts.append(reason) }
        if let m = s.model { parts.append(m) }
        if let e = s.eur { parts.append(String(format: "%.2f euros", e)) }
        return parts.joined(separator: ", ")
    }

    func resourceColor(_ session: CockpitTab) -> Color {
        switch session.resourceState {
        case .healthy: return .secondary
        case .constrained: return .orange
        case .critical: return .red
        }
    }

    func codexProgressText(_ progress: CodexProgressSnapshot) -> String {
        guard progress.commandsCompleted > 0 else { return progress.title }
        return progress.title + " · " + String(progress.commandsCompleted) + " events"
    }

    @ViewBuilder
    func sessionDiagnostics(_ session: CockpitTab) -> some View {
        if let issue = session.resumeIssue {
            Label(issue, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
        if let progress = session.codexProgress {
            Text(codexProgressText(progress))
                .font(.system(size: 10.5))
                .foregroundStyle(progress.phase == .failed ? Color.red : Color.secondary)
                .lineLimit(1)
        }
    }

    func sessionMetricsRow(_ session: CockpitTab) -> some View {
        HStack(spacing: 8) {
            if let euros = session.eur {
                Text(String(format: "€%.2f", euros))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let tokens = session.tokens, tokens > 0 {
                Text(fmtTok(tokens))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if session.isHibernated, let resume = resumeImpactText(session) {
                Text("resume \(resume)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            if let started = session.spawnedAt {
                Text("up \(uptime(started))").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            } else {
                Text("dormant").font(.system(size: 10.5)).foregroundStyle(.quaternary)
            }
        }
    }

    @ViewBuilder
    func sessionResourceRow(_ session: CockpitTab) -> some View {
        if session.ramBytes > 0 {
            HStack(spacing: 5) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(track)
                        Capsule().fill(resourceColor(session).opacity(0.65))
                            .frame(width: max(2, geometry.size.width * ramFraction(session.ramBytes)))
                    }
                }
                .frame(height: 3)
                Text(resourceSummary(session))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(resourceTextColor(session))
            }
        }
    }

    func resourceSummary(_ session: CockpitTab) -> String {
        gb(session.ramBytes) + " · " + String(Int(session.cpuPercent.rounded())) + "% CPU"
    }

    func resourceTextColor(_ session: CockpitTab) -> Color {
        session.resourceState == .healthy ? Color.secondary.opacity(0.7) : resourceColor(session)
    }

    var hibernatedChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "moon.zzz.fill").font(.system(size: 8.5, weight: .semibold))
            Text("hibernated").font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }

    func modelChip(_ m: String) -> some View {
        Text(m).font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(track, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.secondary)
    }

    func gLabel(_ t: String) -> some View {
        Text(LocalizedStringKey(t)).font(.system(size: 8.5, weight: .semibold)).tracking(0.8).foregroundStyle(.tertiary)
    }

    func bar(fraction: Double, tone: Color, estimate: Bool, ticks: Bool) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(estimate ? Color.secondary.opacity(0.6) : tone)
                    .frame(width: max(2, geo.size.width * min(1, fraction)))
                if ticks {
                    ForEach([0.80, 0.95], id: \.self) { t in
                        // L04: blend bg+fg so the 80/95% marks stay visible over
                        // both the empty track AND a saturated orange/red fill.
                        Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.55)).frame(width: 1.5)
                            .offset(x: geo.size.width * t)
                    }
                }
            }
        }.frame(height: 4)
    }

    func pill(_ t: String, soft: Bool = false, solid: Bool = false) -> some View {
        Text(t).font(.system(size: 9, weight: .heavy)).tracking(0.4)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(solid ? Color.primary : (soft ? Color.primary.opacity(0.07) : .clear),
                       in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(solid ? Color(nsColor: .windowBackgroundColor) : .secondary)
    }

    func toneColor(_ pct: Int, estimate: Bool) -> Color {
        if estimate { return .secondary }
        return pct >= 95 ? .red : (pct >= 80 ? .orange : .primary)
    }
    func pressureLabel(_ m: MemoryHealth) -> String {
        m.critical ? "critical" : (m.underPressure ? "warning" : "normal")
    }
    func gb(_ bytes: UInt64) -> String {
        let g = Double(bytes) / 1_073_741_824
        return g >= 10 ? String(format: "%.0fG", g) : String(format: "%.1fG", g)
    }
    /// Per-session RAM bar scale — 4 GB fills the bar (sessions rarely exceed that).
    func ramFraction(_ bytes: UInt64) -> Double { min(1, Double(bytes) / 4_000_000_000) }
    func fmtTok(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }
    func uptime(_ since: Date) -> String {
        let s = Int(Date().timeIntervalSince(since))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}

/// Review gate between native providers. Throttle copies only a bounded local
/// user/assistant excerpt, never tool output or hidden reasoning; the user reviews
/// the exact continuation packet before it reaches the fresh target session.
