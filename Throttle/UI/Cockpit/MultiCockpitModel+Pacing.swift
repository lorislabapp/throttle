import AppKit
import SwiftTerm
import SwiftUI

extension MultiCockpitModel {

    // MARK: - Auto-pause ACT (opt-in, ≥97% binding AND ETA<5min, cancelable)
    //
    // The deferred "risky half" of the circuit breaker (docs/design-circuit-breaker.md):
    // OFF by default, behind explicit consent (`throttleAutoPauseEnabled`). Only fires
    // when the binding window is ≥97% AND a derived burn-ETA to 100% is under 5 min AND
    // a live session is actually burning — then arms a cancelable countdown before a
    // reversible SIGSTOP. Never a hard kill; the user can always cancel or resume.

    // ── Predictive cross-session pacing ──────────────────────────────────────
    // The SOFT tier below auto-pause: when the binding window is climbing toward
    // the cap and MORE THAN ONE session is actively burning, warn early so you can
    // distribute or pause idle sessions YOURSELF, before the hard 95% auto-pause
    // arms. Purely informational + a one-tap convenience — never auto-acts, always
    // on (no token math, reuses the pct-rise ETA). Distinct from auto-pause (hard,
    // single-session, opt-in) and the global cap-ETA notification.
    struct PacingHint: Equatable { let etaText: String; let burning: Int }

    /// Cheap, synchronous, every tick. Sets `pacingHint` when the binding window is
    /// in [80%, auto-pause threshold), rising, ETA-to-cap ≤ 30 min, and ≥2 sessions
    /// are actively burning; clears it otherwise.
    func evaluatePacing() {
        guard let b = binding else { pacingHint = nil; return }
        let pct = Double(b.pct), now = Date()
        let p0 = pcLastPct, t0 = pcLastAt
        pcLastPct = pct; pcLastAt = now
        let burning = sessions.filter { $0.isLive && !$0.isPaused && $0.state == .working }.count
        guard pct >= pcLowPct, pct < apThresholdPct, burning >= 2,
              let p0, let t0 else { pacingHint = nil; return }
        let dt = now.timeIntervalSince(t0), dpct = pct - p0
        guard dt >= 1, dpct > 0 else { pacingHint = nil; return }   // not rising → no wall coming
        let etaSec = (100.0 - pct) / (dpct / dt)
        guard etaSec <= pcEtaHorizon else { pacingHint = nil; return }
        pacingHint = PacingHint(etaText: Self.countdown(Int64(etaSec)), burning: burning)
    }

    /// One-tap from the pacing banner: reversibly SIGSTOP-pause every LIVE session
    /// that isn't the focused one and isn't currently working — reclaim burn from
    /// idle-but-live sessions without touching what you're actively using.
    func pauseIdleSessions() {
        let targets = sessions.filter { $0.isLive && $0.id != activeID && $0.state != .working && !$0.isPaused }
        guard !targets.isEmpty else { return }
        // State-aware: route through the same quiescent-window drain as auto-pause so a
        // bare SIGSTOP never lands mid-flight (NotebookLM Q2). Idle sessions are already
        // non-working, so this almost always fires immediately — but it's correct.
        Task { @MainActor [weak self] in
            guard let self else { return }
            for s in targets { await self.drainThenPause(s, reason: .pacing) }
            self.recomputeSortOrder(); self.persist()
        }
    }

    var autoPauseEnabled: Bool { UserDefaults.standard.bool(forKey: "throttleAutoPauseEnabled") }

    // Rules engine v1 — the concrete rule the planning docs kept asking for:
    // "auto-pause an Opus/Fable session past N tokens". Per-SESSION cap (not the
    // plan wall above): premium-model sessions that balloon are the #1 silent
    // spend, and pausing is reversible (SIGSTOP — resume keeps full context).
    var opusCapEnabled: Bool { UserDefaults.standard.bool(forKey: "throttleOpusTokenCapEnabled") }
    var opusCapTokens: Int {
        let v = UserDefaults.standard.integer(forKey: "throttleOpusTokenCapK")
        return (v > 0 ? v : 200) * 1_000    // default 200k
    }
    func evaluateCacheEfficiencyDrop() {
        guard Date().timeIntervalSince(lastEffCheck) > 3600 else { return }
        lastEffCheck = Date()
        guard let db = appState?.database else { return }
        Task.detached(priority: .utility) {
            guard let e24 = try? await db.read({ try StatsDataService.cacheEfficiency(in: $0, range: .last24h) }),
                  let e7 = try? await db.read({ try StatsDataService.cacheEfficiency(in: $0, range: .last7d) }),
                  e7 > 0.3, e24 < e7 - 0.2 else { return }
            let last = UserDefaults.standard.double(forKey: "throttleCacheEffDropNotifiedAt")
            guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "throttleCacheEffDropNotifiedAt")
            await MainActor.run {
                CockpitNotifier.shared.notifyRule(
                    title: "Cache efficiency dropped",
                    body: String(format: "Hit rate today %.0f%% vs %.0f%% this week — something is busting the prompt cache and the plan burns faster. Dashboard → cache waste says why.", e24 * 100, e7 * 100))
            }
        }
    }

    /// Called each tick after `refreshStats` lands. Pauses any LIVE premium-model
    /// (Opus/Fable) session whose token count crossed the cap. Fires once per
    /// crossing: a manual Resume sets `ruleCapAcknowledged`, so it won't re-pause
    /// until the session drops under the cap again (fresh /compact or new id).
    func evaluateOpusTokenCap() {
        guard opusCapEnabled else { return }
        let cap = opusCapTokens
        for s in sessions {
            guard let model = s.model?.lowercased(),
                  model.contains("opus") || model.contains("fable") || model.contains("mythos"),
                  let tok = s.tokens else { continue }
            if tok < cap { s.ruleCapAcknowledged = false; continue }
            guard s.isSpawned, !s.isPaused, !s.ruleCapAcknowledged else { continue }
            s.ruleCapAcknowledged = true
            s.pauseProcess(reason: .rule("\(model.capitalized) crossed the \(cap / 1_000)k-token cap you set."))
            CockpitNotifier.shared.notifyRule(
                title: "Session paused — \(s.projectName)",
                body: "\(model.capitalized) crossed \(cap / 1_000)k tokens (Opus-cap rule). Resume from the rail when you've checked it.")
        }
    }
}
