import AppKit
import SwiftTerm
import SwiftUI

extension CockpitTab {

    /// Freeze/resume this session's process subtree (SIGSTOP/SIGCONT). No-op if
    /// not spawned. Reversible — never loses state, unlike hibernate (which kills).
    func pauseProcess(reason: PauseReason) {
        guard let pid = shellPid, !isPaused, !isTransitioning, stopIssue == nil else { return }
        SystemMemoryService.signalSubtree(rootPid: pid, signal: SIGSTOP)
        pauseReason = reason
        // Drop keystrokes while the subtree is stopped. They would otherwise sit in
        // the tty buffer and all flush at once on SIGCONT — a stray Return landing on
        // whatever prompt claude was showing. Same reason input is suspended after an
        // agent exit: a pane that looks live must never bank input for later.
        (terminal as? DroppableTerminalView)?.frozen = true
    }
    func resumeProcess() {
        guard allowsProcessLaunch(), !hasRemoteOwnership, let pid = shellPid, isPaused, !isTransitioning,
            stopIssue == nil
        else { return }
        SystemMemoryService.signalSubtree(rootPid: pid, signal: SIGCONT)
        pauseReason = nil
        (terminal as? DroppableTerminalView)?.frozen = false
        lastActivityAt = Date()   // waking is activity; don't let the reclaim sweep re-freeze it
    }

    /// Spawn the terminal on first activation: a login shell, then cd into the
    /// project and launch (or resume) the tab's native runtime.
    func ensureSpawned() {
        guard allowsProcessLaunch(), !hasRemoteOwnership, terminal == nil, !isTransitioning, stopIssue == nil
        else { return }
        if isHibernated, sessionId == nil { requiresNativePicker = runtime.usesTranscript }
        let command: String
        do { command = try agentCommand() } catch {
            resumeIssue = error.localizedDescription
            return
        }
        isHibernated = false
        let term = DroppableTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        // Coalesced to one write per second. `lastActivityAt` feeds `state`,
        // which every session row reads, so writing it per PTY chunk published
        // an @Observable mutation ~40×/s per streaming session — and the rows
        // are functions inlined into `MultiCockpitRoot.body`, so each one
        // invalidated the WHOLE cockpit. Same discipline as `waitingCount`
        // above: assign only when the value would actually move the UI.
        term.onActivity = { [weak self] in
            guard let self, Date().timeIntervalSince(self.lastActivityAt) >= 1 else { return }
            self.lastActivityAt = Date()
        }
        term.onPrompt = { [weak self] question in self?.handlePrompt(question) }
        term.onRateLimit = { [weak self] reset in self?.handleRateLimit(reset) }
        term.onTestOutcome = { [weak self] out in
            guard let self else { return }
            let enc = MultiCockpitModel.claudeProjectDirName(self.cwd)
            let sid = self.sessionId, eur = self.eur
            Task.detached(priority: .utility) {
                TestOutcomeStore.record(project: enc, sessionId: sid, costEUR: eur, outcome: out)
            }
        }
        term.isPausedProvider = { [weak self] in self?.isPaused ?? false }
        term.onTogglePause = { [weak self] in
            guard let self else { return }
            if self.isPaused { self.resumeProcess() } else { self.pauseProcess(reason: .user) }
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        let env = Self.terminalEnvironment()
        term.startProcess(executable: shell, args: [], environment: env, execName: "-\(shellName)")
        rootProcessIdentity = term.process.flatMap { NativeProcessIdentity.capture($0.shellPid) }
        if let rootProcessIdentity { LiveAgentRoots.register(rootProcessIdentity) }
        CockpitTerminalTheme.apply(to: term)   // after spawn so the engine is live + a redraw is queued
        // Low-memory mode: trim the scrollback (default 500) to 150 rows. A small
        // win on its own — the buffer is tiny next to the Node subtree — but it cuts
        // per-scroll redraw work, which is what actually stutters on the beta.
        let lowMem = UserDefaults.standard.bool(forKey: "throttleLowMemoryMode")
        if lowMem { term.changeScrollback(150) }
        self.terminal = term
        self.spawnedAt = Date()                // real process start → honest uptime

        term.send(txt: command + "\n")
    }

    /// SwiftTerm's `getEnvironmentVariables` is a fixed whitelist (TERM/LANG/…)
    /// that drops `SSH_AUTH_SOCK` — so any `ssh` inside a cockpit session (e.g. an
    /// MCP server launched as `ssh root@…`, like lorislab-comms) couldn't reach the
    /// agent and prompted "Enter passphrase for key …" straight into claude's
    /// terminal on every session start. Forward the socket so keychain-loaded keys
    /// work exactly like they do in Terminal.app.
    static func terminalEnvironment() -> [String] {
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        if let sock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
            env.append("SSH_AUTH_SOCK=\(sock)")
        }
        return env
    }

    /// Spawn the side shell on first open: a login shell cd'd into the project —
    /// no claude, just an interactive zsh for ad-hoc CLI beside the conversation.
    func ensureShellSpawned() {
        guard allowsProcessLaunch(), !hasRemoteOwnership, shellTerminal == nil, !isTransitioning,
            stopIssue == nil
        else { return }
        let term = DroppableTerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 480))
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        let env = Self.terminalEnvironment()
        term.startProcess(executable: shell, args: [], environment: env, execName: "-\(shellName)")
        sideShellIdentity = term.process.flatMap { NativeProcessIdentity.capture($0.shellPid) }
        if let sideShellIdentity { LiveAgentRoots.register(sideShellIdentity) }
        CockpitTerminalTheme.apply(to: term)
        if UserDefaults.standard.bool(forKey: "throttleLowMemoryMode") { term.changeScrollback(150) }
        shellTerminal = term
        // Drop the user straight into the project dir, matching the claude session's cwd.
        let quoted = "'" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        term.send(txt: "cd \(quoted) && clear\n")
    }

    /// Capture both process trees before any signal and retain their terminals
    /// until the captured scope has exited. Competing actions cannot replace it.
    /// Unknown ownership remains a visible recovery state, never an exit receipt.
    @discardableResult
    func hibernate() async -> Bool {
        guard !isStopping, stopIssue == nil else { return false }
        guard terminal != nil || shellTerminal != nil else { return true }
        guard terminal == nil || rootProcessIdentity != nil,
              shellTerminal == nil || sideShellIdentity != nil else {
            (terminal as? DroppableTerminalView)?.inputSuspended = true
            shellTerminal?.inputSuspended = true
            stopIssue = "Cannot identify this session's processes. Review them before continuing."
            return false
        }
        isStopping = true
        (terminal as? DroppableTerminalView)?.inputSuspended = true
        shellTerminal?.inputSuspended = true
        defer { isStopping = false }
        let roots = [rootProcessIdentity, sideShellIdentity].compactMap { $0 }
        let outcome = await Task.detached(priority: .userInitiated) {
            guard let scope = OwnedProcessTermination.capture(roots: roots) else {
                return OwnedProcessTermination.Outcome.failed(
                    "Cannot confirm which processes belong to this session. No replacement was started.")
            }
            return OwnedProcessTermination.stop(scope)
        }.value
        guard outcome == .stopped else {
            if case .failed(let issue) = outcome { stopIssue = issue }
            return false
        }
        for root in roots { LiveAgentRoots.unregister(root.pid) }
        if sessionId == nil { requiresNativePicker = runtime.usesTranscript }
        terminal = nil
        shellTerminal = nil
        rootProcessIdentity = nil
        sideShellIdentity = nil
        ramBytes = 0
        isLive = false
        needsInput = false
        pauseReason = nil      // the SIGSTOP is moot once the subtree is killed; don't
                               // leave a stale freeze flag on the hibernated (or woken) tab
        isHibernated = true
        return true
    }

    /// Restart this session in place to reclaim leaked/ballooned RAM: hibernate
    /// (kills the subtree, snapshots the resume-id) then immediately respawn via
    /// `claude --resume`, so the leaked node heap is freed but the conversation
    /// continues with full context. The user-triggered answer to a suspected leak.
    func restartInPlace() async {
        guard allowsProcessLaunch(), !hasRemoteOwnership, terminal != nil, !isTransitioning, await hibernate()
        else { return }
        ensureSpawned()
        leakSuspected = false
    }
}
