import AppKit
import SwiftTerm
import SwiftUI

extension MultiCockpitModel {

    /// Called each tick. Derives ETA-to-100% from the binding-pct rise (same method as
    /// `ThresholdNotifier`, so no token-cap math needed) and arms the countdown when all
    /// guards pass. Cheap + synchronous; `binding` reads `AppState.snapshot` directly.
    func evaluateAutoPause() {
        guard autoPauseEnabled else { if autoPauseTask != nil { cancelAutoPause() }; return }
        guard autoPauseTask == nil else { return }          // a countdown is already running
        guard let b = binding else { return }
        let pct = Double(b.pct), now = Date()
        let p0 = apLastPct, t0 = apLastAt
        apLastPct = pct; apLastAt = now
        guard pct >= apThresholdPct, let p0, let t0 else { return }
        let dt = now.timeIntervalSince(t0)
        guard dt >= 1 else { return }
        let dpct = pct - p0
        guard dpct > 0 else { return }                      // not rising → no imminent wall
        let etaSec = (100.0 - pct) / (dpct / dt)
        guard etaSec <= apEtaHorizon else { return }
        guard sessions.contains(where: { $0.isLive && !$0.isPaused }) else { return }
        armAutoPause()
    }

    func armAutoPause() {
        autoPauseCountdown = apGraceSeconds
        autoPauseTask = Task { [weak self] in
            while let left = self?.autoPauseCountdown, left > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                guard let self else { return }
                self.autoPauseCountdown = (self.autoPauseCountdown ?? 1) - 1
            }
            guard !Task.isCancelled else { return }
            await self?.fireAutoPause()
        }
    }

    /// User (or a disable) cancels the pending pause. Resets the sample so it must
    /// rise again before re-arming — no instant re-trigger on the next tick.
    func cancelAutoPause() {
        autoPauseTask?.cancel(); autoPauseTask = nil
        autoPauseCountdown = nil
        apLastPct = nil; apLastAt = nil
    }

    func fireAutoPause() async {
        // Target the actual runaway, not every live session: if any session is flagged
        // as looping, freeze ONLY those; otherwise fall back to all live sessions. Keeps
        // the blast radius minimal (NotebookLM: don't freeze the whole fleet).
        let looping = sessions.filter { $0.isLive && !$0.isPaused && $0.loopSignal != nil }
        let targets = looping.isEmpty ? sessions.filter { $0.isLive && !$0.isPaused } : looping
        for s in targets { await drainThenPause(s, reason: .capBreaker) }
        autoPauseTask = nil
        autoPauseCountdown = nil
        apLastPct = nil; apLastAt = nil
    }

    /// Prefer a brief quiet interval in this tab's exact transcript before pausing.
    /// This is a bounded heuristic: file mtime cannot prove socket or tool quiescence.
    /// Revalidate the tab generation after each suspension so a replacement is never
    /// paused by work scheduled for its predecessor.
    func drainThenPause(_ session: CockpitTab, reason: CockpitTab.PauseReason) async {
        let generation = session.pauseGeneration
        let runtime = session.runtime
        let cwd = session.cwd
        let transcript = await Task.detached(priority: .utility) {
            guard let id = generation.sessionID else { return nil as URL? }
            let urls = runtime == .codex
                ? CodexUsageService.recentRolloutURLs(
                    root: URL.homeDirectory.appendingPathComponent(".codex/sessions"), now: Date())
                : []
            return NativeSessionBinding.knownTranscript(
                runtime: runtime, id: id, cwd: cwd, codexURLs: urls)?.url
        }.value
        let deadline = Date().addingTimeInterval(4)
        var last = transcript.flatMap(Self.transcriptModificationDate)
        repeat {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, !isQuitting,
                  sessions.contains(where: { $0 === session }),
                  session.canPause(generation: generation) else { return }
            let now = transcript.flatMap(Self.transcriptModificationDate)
            if let now, let last, now == last { break }
            last = now
        } while Date() < deadline
        session.pauseProcess(reason: reason)
    }

    nonisolated static func transcriptModificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
