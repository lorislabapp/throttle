import AppKit
import SwiftTerm
import SwiftUI

extension MultiCockpitModel {

    /// Opening another session would push the Mac past saturation.
    var gated: Bool { machine.critical }

    // MARK: - Auto-hibernate under memory pressure (MEM-H01)

    /// Default-ON, reversible: under critical memory pressure, hibernate sessions
    /// that have been idle a while to reclaim their ~300 MB–1 GB subtree RSS —
    /// the single biggest RAM lever on a 16 GB Mac deep in swap. Unlike SIGSTOP
    /// pause (freezes token burn but keeps resident pages), hibernate KILLS the
    /// subtree and frees the pages; the tab wakes via `claude --resume` with full
    /// context. Never touches the active/working/waiting/paused/rate-limited tab.
    var autoHibernateEnabled: Bool {
        // Low-memory mode forces reclaim on regardless of the individual toggle —
        // it's the single biggest anti-swap lever, so the master switch owns it.
        if lowMemoryMode { return true }
        return UserDefaults.standard.object(forKey: "throttleAutoHibernateEnabled") as? Bool ?? true
    }
    /// How long a tab must sit idle before it's a hibernation candidate. Low-memory
    /// mode reclaims 3× sooner (5 min vs 15) to keep resident pages — and swap — low.
    var autoHibIdleSeconds: TimeInterval { lowMemoryMode ? 5 * 60 : 15 * 60 }

    /// Master switch for the 16 GB Mac (see [[kevin-mac-memory-constraint]]): tightens
    /// every reclaim threshold at once instead of making the user tune four settings.
    /// Reversible, reads-through — never overwrites the individual prefs it shadows.
    var lowMemoryMode: Bool {
        UserDefaults.standard.bool(forKey: "throttleLowMemoryMode")
    }

    /// Also reclaim proactively when too many sessions are spawned at once —
    /// macOS memory compression masks pressure until it's extreme, so waiting for
    /// `machine.critical` reclaims too late. 0 = off. Default 6; low-memory caps at 3.
    var maxLiveSessions: Int {
        let stored = UserDefaults.standard.object(forKey: "throttleMaxLiveSessions") as? Int ?? 6
        if lowMemoryMode { return stored > 0 ? min(stored, 3) : 3 }
        return stored
    }

    func autoHibernateIfPressured() {
        let spawnedCount = sessions.filter { $0.isSpawned && !$0.isHibernated }.count
        let crowded = maxLiveSessions > 0 && spawnedCount > maxLiveSessions
        guard autoHibernateEnabled, machine.critical || crowded else { return }
        // Debounce FIRST. This guard used to sit *after* `refreshActivityFromCPU()`,
        // which forks `/bin/ps` and reads 64 KB of JSONL per Claude tab — on the
        // main actor. So the full sweep ran on every 10 s tick and on every
        // memory-pressure rise, and its result was then usually thrown away by
        // this very check. Worse, those reads land as page-ins precisely when the
        // Mac is swapping: the code that exists to relieve pressure was adding to
        // it, on the thread that draws.
        guard Date().timeIntervalSince(lastAutoHibernateAt) > 120 else { return }
        // Must run before victim selection, including on the out-of-band pressure-rise
        // path — otherwise a build that has been silent for 5 minutes is a victim.
        refreshActivityFromCPU()
        let now = Date()
        let idleLongEnough: (CockpitTab) -> Bool = { [autoHibIdleSeconds] in
            now.timeIntervalSince($0.lastActivityAt) >= autoHibIdleSeconds
        }

        if machine.critical {
            // Real pressure → hard-free RAM. Kill idle live tabs, AND escalate our own
            // auto-paused tabs (pages cold but still resident); never a USER-paused tab
            // (explicit intent) or the focused one. Wakes via --resume (token cost is
            // justified when memory is genuinely scarce).
            let victims = sessions.filter {
                $0.isSpawned && !$0.isHibernated && !$0.isTransitioning && $0.stopIssue == nil
                    && !$0.isRateLimited && $0.id != activeID
                && ($0.state == .idle || $0.pauseReason?.escalatesToHibernate == true)
                && idleLongEnough($0)
            }
            hibernateIdleVictims(victims, at: now)
        } else {
            // Crowded but RAM fine → freeze instead of kill. Route through the same
            // quiescent-window drain as manual/auto pause so a bare SIGSTOP never lands
            // mid-flight; idle victims are already non-working so it almost always fires
            // at once. Wake is instant on focus — no --resume, no tokens, no prompt.
            let victims = sessions.filter {
                $0.isSpawned && !$0.isPaused && !$0.isHibernated && !$0.isRateLimited
                && $0.id != activeID                   // never the focused tab
                && $0.state == .idle                   // excludes working/waiting/dormant
                && idleLongEnough($0)
            }
            freezeIdleVictims(victims, at: now)
        }
    }

    private func hibernateIdleVictims(_ victims: [CockpitTab], at now: Date) {
        guard !victims.isEmpty else { return }
        lastAutoHibernateAt = now
        Task { @MainActor [weak self] in
            guard let self else { return }
            var stopped: [CockpitTab] = []
            var freed: UInt64 = 0
            for victim in victims {
                guard victim.id != self.activeID, !victim.isTransitioning,
                      self.sessions.contains(where: { $0.id == victim.id }) else { continue }
                let memory = victim.ramBytes
                if await victim.hibernate() { stopped.append(victim); freed += memory }
            }
            self.recomputeSortOrder()
            self.persist()
            guard !stopped.isEmpty else { return }
            CockpitNotifier.shared.notifyAutoHibernate(
                count: stopped.count,
                freedBytes: freed,
                resumeContextTokens: stopped.compactMap(\.promptCacheImpact).reduce(0) { $0 + $1.contextTokens },
                resumeRebuildEUR: stopped.compactMap(\.promptCacheImpact).reduce(0) { $0 + $1.rebuildEUR }
            )
        }
    }

    private func freezeIdleVictims(_ victims: [CockpitTab], at now: Date) {
        guard !victims.isEmpty else { return }
        lastAutoHibernateAt = now
        Task { @MainActor [weak self] in
            guard let self else { return }
            for victim in victims { await self.drainThenPause(victim, reason: .crowding) }
            let paused = victims.filter { $0.pauseReason == .crowding }.count
            self.recomputeSortOrder()
            self.persist()
            CockpitNotifier.shared.notifyAutoPause(count: paused)
        }
    }

    func sampleMachine() {
        Task { [weak self] in
            let h = await Task.detached(priority: .utility) { SystemMemoryService.sample() }.value
            self?.machine = h
        }
    }

    /// Real per-session RAM: resident memory of each spawned tab's process
    /// subtree (shell → claude → node). One `ps` sweep, off-main.
    func sampleSessionRAM() {
        let pairs = sessions.compactMap(CockpitProcessProbe.init)
        guard !pairs.isEmpty else { return }
        let pids = pairs.map { $0.identity.pid }
        Task { [weak self] in
            let map = await Task.detached(priority: .utility) { SystemMemoryService.subtreeRSS(rootPids: pids) }.value
            guard let self else { return }
            for probe in pairs {
                let id = probe.id, identity = probe.identity, spawnedAt = probe.spawnedAt
                if let bytes = map[identity.pid], let tab = self.sessions.first(where: { $0.id == id }),
                   tab.rootProcessIdentity == identity, tab.spawnedAt == spawnedAt, !tab.isTransitioning {
                    tab.ramBytes = bytes
                    // Leak heuristic (#4953): Claude Code's node process can grow
                    // unbounded on long sessions/subagents. Flag a ballooned subtree
                    // so the UI can nudge a restart-in-place (reclaims the leaked
                    // heap, keeps context via --resume) — advisory, never automatic.
                    tab.leakSuspected = bytes >= CockpitTab.resourceEnvelope.warningBytes
                }
            }
        }
    }
}
