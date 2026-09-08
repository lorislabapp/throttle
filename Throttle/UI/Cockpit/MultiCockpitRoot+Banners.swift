import AppKit
import SwiftUI
import ThrottleShared

extension MultiCockpitRoot {
    // MARK: - Global strip (binding + machine)

    var globalStrip: some View {
        HStack(spacing: 0) {
            bindingCell
            Rectangle().fill(hair).frame(width: 1, height: 48)
            machineCell
            Spacer(minLength: 0)
        }
        .frame(height: 76)
        .overlay(alignment: .bottom) { Rectangle().fill(hair).frame(height: 1) }
    }

    var bindingCell: some View {
        VStack(alignment: .leading, spacing: 5) {
            gLabel("BINDING · ALL SESSIONS")
            if let b = model.binding {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    HStack(spacing: 0) {
                        if b.estimate { Text("≈").font(.system(size: 13)).foregroundStyle(.tertiary) }
                        Text("\(b.pct)").font(.system(size: 26, weight: .regular, design: .monospaced))
                            .foregroundStyle(toneColor(b.pct, estimate: b.estimate))
                        Text("%").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Text("\(b.name)\nresets \(b.reset)\(b.resetInSeconds.map { " · in \(MultiCockpitModel.countdown($0))" } ?? "")")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                bar(fraction: Double(b.pct) / 100, tone: toneColor(b.pct, estimate: false),
                    estimate: b.estimate, ticks: true)
            } else {
                Text("—").font(.system(size: 26, weight: .regular, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 9).frame(width: 240, alignment: .leading)
    }

    var machineCell: some View {
        let m = model.machine
        let tint: Color = m.critical ? .red : (m.underPressure ? .orange : .secondary)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                gLabel("MACHINE")
                // Quiet mode: Throttle backs off its own scans under memory pressure.
                // Graphite tag, no pressure colour (memory ≠ cap pressure).
                if MemoryPressureMonitor.shared.isQuiet {
                    Text("quiet").font(.system(size: 8.5, weight: .semibold)).textCase(.lowercase).foregroundStyle(.tertiary)
                        .padding(.horizontal, 4).padding(.vertical, 1).overlay(Capsule().strokeBorder(hair, lineWidth: 1))
                        .help("Memory pressure — Throttle paused its background scans to free RAM")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 0) {
                    Text(gb(m.usedBytes)).font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundStyle(m.underPressure ? tint : .primary)
                    Text("/\(gb(m.totalBytes))").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                HStack(spacing: 4) {
                    Circle().fill(tint).frame(width: 6, height: 6)
                    Text(pressureLabel(m) + " · " + m.agentSummary
                         + (m.swapUsedBytes > 0 ? " · swap \(gb(m.swapUsedBytes))" : ""))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            bar(fraction: m.usedFraction, tone: tint, estimate: false, ticks: false).frame(width: 168)
        }
        .padding(.horizontal, 15).padding(.vertical, 9).frame(minWidth: 196, alignment: .leading)
    }

    var gateBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.red)
            HStack(spacing: 0) {
                Text("Mac saturated").font(.system(size: 11.5, weight: .semibold))
                Text(" — close a session before opening another.").font(.system(size: 11.5))
            }
            .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.red.opacity(0.10))
    }

    /// The loop detector flagged a session cycling the same action with no file
    /// changes — likely a runaway "Ralph Wiggum" loop burning tokens. Advisory:
    /// offers the (already-shipped) Pause; never auto-pauses.
    @ViewBuilder
    func loopBanner(_ s: CockpitTab) -> some View {
        if let sig = s.loopSignal {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12)).foregroundStyle(.orange)
                Text("\(s.projectName): possible runaway loop — \(sig.repeatedTool) ×\(sig.repeats), no file changes\(sig.tokensBurned > 0 ? " · ≈\(fmtTok(sig.tokensBurned)) tok burned" : "").")
                    .font(.system(size: 11.5)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 0)
                if s.isSpawned {
                    Button(s.isPaused ? "Resume" : "Pause") { s.isPaused ? s.resumeProcess() : s.pauseProcess(reason: .user) }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.accentColor)
                }
                Button { s.loopSignal = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.orange.opacity(0.10))
        }
    }

    /// A session's node subtree has ballooned (leak #4953). Offer a restart-in-place
    /// that reclaims the leaked heap while keeping context via --resume. Advisory.
    func leakBanner(_ s: CockpitTab) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "memorychip").font(.system(size: 12)).foregroundStyle(.orange)
            Text("\(s.projectName): \(s.resourceReason ?? "sampled resource pressure") at \(ByteCountFormatter.string(fromByteCount: Int64(s.ramBytes), countStyle: .memory)), \(Int(s.cpuPercent.rounded()))% CPU. Restart reclaims RAM, but resume may rebuild \(resumeImpactText(s) ?? "the prompt cache").")
                .font(.system(size: 11.5)).foregroundStyle(.primary).lineLimit(1)
            Spacer(minLength: 0)
            Button("Restart") { Task { await s.restartInPlace() } }
                .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.accentColor)
            Button { s.leakSuspected = false } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    /// One or more sessions hit the account usage cap. Account limits are shared
    /// across every session, so this flags WHICH are blocked + the soonest reset.
    var rateLimitBanner: some View {
        let blocked = model.rateLimitedSessions
        let names = blocked.map(\.projectName).joined(separator: ", ")
        let eta = model.soonestRateLimitReset.map { MultiCockpitModel.countdown(Int64($0.timeIntervalSinceNow)) }
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 12)).foregroundStyle(.red)
            Text(blocked.count == 1
                 ? "\(names) hit the usage limit\(eta.map { " — frees up in \($0)" } ?? "")."
                 : "\(blocked.count) sessions rate-limited (\(names))\(eta.map { " — soonest frees up in \($0)" } ?? "").")
                .font(.system(size: 11.5)).foregroundStyle(.primary).lineLimit(1)
            Spacer(minLength: 0)
            if let first = blocked.first {
                if first.runtime == .claudeCode {
                    Button("Continue with Codex") { requestHandoff(first, to: .codex) }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.accentColor)
                }
                Button("Show") { model.wake(first.id) }
                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.red.opacity(0.10))
    }

    /// Soft pacing tier (below auto-pause): several sessions burning toward the
    /// shared cap. Informational + a one-tap "Pause idle" convenience; never acts
    /// on its own. Suppressed while the auto-pause countdown is showing.
    func pacingBanner(_ hint: MultiCockpitModel.PacingHint) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.needle").font(.system(size: 12)).foregroundStyle(.orange)
            Text("\(hint.burning) sessions burning — ≈\(hint.etaText) to your cap.")
                .font(.system(size: 11.5)).foregroundStyle(.primary).lineLimit(1)
            Spacer(minLength: 0)
            Button("Pause idle") { model.pauseIdleSessions() }
                .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.accentColor)
            Button { model.pacingHint = nil } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    /// Auto-pause ACT armed: binding ≥97% + imminent wall. Cancelable countdown
    /// before a reversible SIGSTOP of the live sessions. Opt-in; never a kill.
    func autoPauseBanner(_ seconds: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill").font(.system(size: 12)).foregroundStyle(.orange)
            Text("Near the usage cap — auto-pausing live sessions in \(seconds)s to save your quota.")
                .font(.system(size: 11.5)).foregroundStyle(.primary).lineLimit(1)
            Spacer(minLength: 0)
            Button("Cancel") { model.cancelAutoPause() }
                .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.accentColor)
                .help("Keep running — don't pause. (You can also disable auto-pause in Settings.)")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    /// Same project open in >1 live session = wasted RAM + tokens. Offer a
    /// 1-click consolidate (hibernate the extras, keep the most-recent; resume-id
    /// preserved → nothing lost).
    var duplicateBanner: some View {
        let names = model.duplicateCwds
            .map { cwd in (cwd as NSString).lastPathComponent }
            .sorted().joined(separator: ", ")
        return HStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle").font(.system(size: 12)).foregroundStyle(.orange)
            Text("Same project open twice: \(names) — wasting RAM + tokens.")
                .font(.system(size: 11.5)).foregroundStyle(.primary)
            Spacer(minLength: 0)
            Button("Consolidate") { model.consolidateDuplicates() }
                .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.accentColor)
                .help("Hibernate the extra session(s), keep the most recent — nothing lost")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    /// Shown when a hidden session needed you but notifications are off (C02) —
    /// so the "never lose a background prompt" promise degrades visibly.
    var notifDeniedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.slash.fill").font(.system(size: 12)).foregroundStyle(.orange)
            Text("A background session needs you, but notifications are off.")
                .font(.system(size: 11.5)).foregroundStyle(.primary)
            Spacer(minLength: 0)
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                    NSWorkspace.openInBackground(url)
                }
            }.buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.accentColor)
            Button { showNotifBanner = false } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }
}
