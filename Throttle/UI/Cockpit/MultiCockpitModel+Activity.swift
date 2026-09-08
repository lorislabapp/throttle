import AppKit
import SwiftTerm
import SwiftUI

extension MultiCockpitModel {

    /// True when the tab's claude is executing a tool right now: the transcript's last
    /// tool event is a `tool_use` with no `tool_result` after it. Covers the case CPU
    /// can't see — a tool that is silent AND burns nothing while it waits on the
    /// network. Any parse failure returns false: fall back to the other signals rather
    /// than protect a tab on a guess.
    nonisolated static func isMidToolCall(cwd: String, sessionId: String, now: Date) -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(claudeProjectDirName(cwd))/\(sessionId).jsonl")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return false }
        let window: UInt64 = 64 * 1024
        let start = end > window ? end - window : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return false }

        var lines = text.split(separator: "\n").map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() }   // partial line at the window edge

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in lines.reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            let kinds = content.compactMap { $0["type"] as? String }
            // Whichever comes last wins: a tool_result closes the call, a tool_use opens one.
            if kinds.contains("tool_result") { return false }
            guard kinds.contains("tool_use") else { continue }
            guard let stamp = obj["timestamp"] as? String, let at = iso.date(from: stamp) else { return false }
            return now.timeIntervalSince(at) < maxToolCallProtection
        }
        return false
    }

    /// Promote silent-but-working sessions to `.working` before any reclaim decision.
    /// Without this, "no terminal output for 5 minutes" is the entire definition of
    /// idle — and that is exactly what a session running a long build looks like.
    func refreshActivityFromCPU() {
        let live = sessions.filter {
            $0.isSpawned && !$0.isHibernated && !$0.isTransitioning && $0.stopIssue == nil && !$0.isPaused
        }
        let pids = live.compactMap { $0.shellPid }
        guard !pids.isEmpty else { return }
        let cpu = SystemMemoryService.subtreeCPUSeconds(rootPids: pids)
        let now = Date()
        for tab in live {
            // Mid-tool beats every other signal: claude is working by definition, even
            // if the tool prints nothing and burns no CPU while it waits.
            if tab.runtime == .claudeCode, let sid = tab.sessionId,
               Self.isMidToolCall(cwd: tab.cwd, sessionId: sid, now: now) {
                tab.lastActivityAt = now
            }
            guard let pid = tab.shellPid, let total = cpu[pid] else { continue }
            // No baseline yet (first tick after spawn/wake): treat as active. The next
            // tick has a real delta; until then, never reclaim on a guess.
            guard let previous = tab.lastCPUSeconds else {
                tab.lastCPUSeconds = total
                tab.lastCPUSampleAt = now
                tab.lastActivityAt = now
                continue
            }
            let wall = now.timeIntervalSince(tab.lastCPUSampleAt)
            // Too soon to measure — keep the old baseline rather than sliding it, or
            // a burst of pressure-rise callbacks would reset the window every time and
            // no session would ever register as busy.
            guard wall >= 1 else { continue }
            let percent = total >= previous ? (total - previous) / wall * 100 : 0
            tab.recordCPUPercent(percent)
            if percent >= Self.busyCPUPercent {
                tab.lastActivityAt = now
            }
            tab.lastCPUSeconds = total
            tab.lastCPUSampleAt = now
        }
    }

    /// Poll for tabs whose agent has exited while its login shell lived on.
    ///
    /// Nothing in Throttle causes this: `pauseProcess` is a clean SIGSTOP and
    /// `hibernate` drops the terminal entirely. The agent leaves for its own
    /// reasons — a clean exit after a long idle, a crash, a reclaim. What
    /// Throttle owes the user is noticing, because the pane gives no sign: the
    /// PTY belongs to the shell, and `isLive` only reports transcript mtime,
    /// which says "wrote recently", never "still exists".
    ///
    /// A clean single exit resumes in place. A second exit inside the flap
    /// window suspends input instead — at that point relaunching is not a fix.
    func detectAgentExit() {
        let candidates = sessions.filter {
            $0.isSpawned && !$0.isHibernated && !$0.isTransitioning && $0.stopIssue == nil && !$0.isPaused
                && !$0.agentExited
                && $0.runtime.executable != nil
        }
        let pairs = candidates.compactMap(CockpitProcessProbe.init)
        guard !pairs.isEmpty else { return }
        let names = Set(candidates.compactMap(\.runtime.executable))
        let pids = pairs.map { $0.identity.pid }
        Task { [weak self] in
            let alive = await Task.detached(priority: .utility) {
                SystemMemoryService.subtreeHasAgent(rootPids: pids, names: names)
            }.value
            guard let self else { return }
            for probe in pairs {
                let id = probe.id, identity = probe.identity, spawnedAt = probe.spawnedAt
                // Absent from the map means the probe could not answer. Treat that
                // as "still there": suspending input or relaunching on a failed
                // `ps` would be worse than missing one exit.
                guard !self.isQuitting, alive[identity.pid] == false,
                      let tab = self.sessions.first(where: { $0.id == id }),
                      tab.rootProcessIdentity == identity, tab.spawnedAt == spawnedAt,
                      // Re-check: the tab may have been paused or hibernated while
                      // the probe was running off-thread.
                    tab.isSpawned, !tab.isHibernated, !tab.isTransitioning, tab.stopIssue == nil,
                    !tab.isPaused, !tab.agentExited
                else { continue }
                if tab.noteAgentExit() {
                    tab.relaunchAgent()
                } else {
                    CockpitNotifier.shared.notifyAgentExited(project: tab.projectName)
                }
            }
        }
    }
}
