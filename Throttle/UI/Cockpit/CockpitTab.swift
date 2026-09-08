import AppKit
import SwiftTerm
import SwiftUI

/// One project session in the multi-cockpit: a real login-shell terminal
/// running Claude Code or Codex in the project's cwd, plus the live metadata
/// the decision layer shows. Per-session
/// cost/model are real-or-nil — never faked (the golden rule); they stay nil
/// until a data-linking pass wires them to StatsDataService.
@MainActor
@Observable
final class CockpitTab: Identifiable {
    let id = UUID()
    let projectName: String
    let cwd: String
    let missionID: UUID
    let runtime: AgentRuntime
    /// When this TAB was created (cockpit launch / new session) — used as the
    /// since-floor for transcript discovery. NOT the session's run time.
    let startedAt = Date()
    /// When the live agent PROCESS actually spawned — the real uptime. nil
    /// until spawned (a dormant restored tab has no running process, so it shows
    /// no uptime instead of the misleading shared "cockpit has been open Xm").
    var spawnedAt: Date?

    /// LAZY: nil until the tab is first activated (memory-safe restore — a
    /// dormant restored tab costs nothing until you open it).
    var terminal: LocalProcessTerminalView?
    @ObservationIgnored var rootProcessIdentity: NativeProcessIdentity?
    @ObservationIgnored var sideShellIdentity: NativeProcessIdentity?
    var isStopping = false
    var isTransferring = false
    var isTransitioning: Bool { isStopping || isTransferring }
    var stopIssue: String?
    @ObservationIgnored var allowsProcessLaunch: () -> Bool = { true }
    @ObservationIgnored var allowsNativePicker: () -> Bool = { true }
    var sideShellPIDForRecovery: pid_t? { sideShellIdentity?.pid }

    var foregroundProcessGroup: pid_t? {
        guard let descriptor = terminal?.process?.childfd, descriptor >= 0 else { return nil }
        let group = tcgetpgrp(descriptor)
        return group > 1 ? group : nil
    }
    /// LAZY side shell: a plain login zsh in the project's cwd, hosted in the
    /// split pane beside claude. nil until the user first opens the shell on this
    /// tab. NOT a claude subtree — just a shell (~10 MB), so cheap to keep.
    var shellTerminal: DroppableTerminalView?
    /// When restoring, resume the exact prior native agent session.
    let resumeSessionId: String?
    /// Provider-neutral continuation packet supplied only when a handoff creates
    /// a fresh native session. It is passed as the CLI's first prompt.
    let initialPrompt: String?
    var freshClaudeSessionID: String?
    var requiresNativePicker = false
    var isChoosingNativeSession = false

    // Live metadata — nil = "not yet known", rendered as ≈/— (never invented).
    var model: String?
    var eur: Double?
    var tokens: Int?
    /// Latest observed request context. Used to price a likely cold prefill
    /// before model switches and after a hibernated `--resume`.
    var promptCacheImpact: PromptCacheImpact?
    var codexProgress: CodexProgressSnapshot?
    var isLive = false
    /// claude appears to be blocked on a prompt the user hasn't answered.
    /// The `didSet` keeps `MultiCockpitModel.waitingCount` in sync on the exact
    /// transitions — see that property for why the menu bar must never read this
    /// one across all tabs.
    var needsInput = false {
        didSet {
            guard needsInput != oldValue else { return }
            MultiCockpitModel.shared.refreshWaitingCount()
        }
    }
    /// Recent detected questions (newest last), capped — the "don't lose it" feed.
    var questions: [Question] = []
    /// Called by the model when a hidden session raises a question (→ notify).
    var onQuestion: ((CockpitTab, String) -> Void)?
    /// Last time the session emitted output (for live/idle heuristics).
    var lastActivityAt = Date()
    /// Cumulative CPU-seconds of this tab's subtree at `lastCPUSampleAt`. Compared
    /// tick-to-tick so a session that is working silently — compiling, running tests,
    /// waiting on a long `bash` tool call — is not mistaken for an idle one. Terminal
    /// output alone cannot tell those apart: a 10-minute build prints nothing.
    var lastCPUSeconds: Double?
    var lastCPUSampleAt = Date()
    var cpuPercent: Double = 0
    var consecutiveHighCPUSamples = 0
    /// Set when claude prints a usage/rate-limit message; cleared once the stated
    /// reset time passes. Drives the `.rateLimited` state + cockpit banner.
    var rateLimitedUntil: Date?
    /// Set when the loop detector spots a runaway cycle (same action, no file
    /// changes) burning tokens. Advisory — drives a nudge, never auto-pauses.
    var loopSignal: LoopSignal?
    /// Hibernated = process subtree terminated to free RAM, resume-id kept.
    /// Distinct from a never-opened restored tab (both have terminal == nil).
    var isHibernated = false
    /// Set when this session's subtree RSS has ballooned past the leak threshold
    /// (Claude Code node leak #4953). Advisory only — drives a "restart to reclaim"
    /// nudge, never an automatic restart.
    var leakSuspected = false
    /// Resident memory of this session's process subtree (shell → claude → node).
    var ramBytes: UInt64 = 0
    /// The running claude session id, discovered at runtime — used for persistence.
    var sessionId: String?
    /// Human-readable recovery diagnostic. The terminal remains usable and, for
    /// Codex, opens its native session picker when an exact saved ID is missing.
    var resumeIssue: String?
    /// Set when this session's transcript was offloaded to the edge box — the
    /// remote session id it resumed as. Lets the decision menu say "already
    /// offloaded" instead of silently re-uploading.
    var offloadedRemoteID: String?
    /// Opus-token-cap rule latch: true after the rule paused (or the user resumed
    /// past) this session, cleared when it drops back under the cap.
    var ruleCapAcknowledged = false
    /// Previous dominant model, for the mid-session swap detector (a swap
    /// orphans the per-model prompt cache — usually costs MORE, not less).
    var lastSeenModel: String?
    /// Target selected through Throttle's cache-aware confirmation. Suppresses
    /// the redundant after-the-fact notification; terminal-entered `/model`
    /// changes still get the detector notification.
    var confirmedModelSwitchTarget: String?

    /// Rich session state for the rail dot — replaces the binary live/gray flicker.
    /// `working` covers BOTH claude streaming AND the user typing (lastActivityAt
    /// is bumped on keystrokes too), so the "claude is thinking before the first
    /// token" gap no longer reads as idle.
    /// WHY this session is frozen (nil = running). Every SIGSTOP in the app carries
    /// a reason, because the two policies that used to hang off a loose `autoPaused`
    /// bool — "does focusing it wake it?" and "may pressure escalate it to hibernate?"
    /// — are properties of the reason, not of the caller who happened to remember to
    /// set the flag. It was set on exactly one of the three automatic pause paths, so
    /// a tab frozen by the pacing one-tap or the cap breaker stayed frozen when you
    /// focused it, with nothing on screen saying why.
    var pauseReason: PauseReason?

    /// PID of the session's login shell (root of its process subtree), if spawned.
    var shellPid: Int32? {
        guard let pid = terminal?.process?.shellPid, pid > 0 else { return nil }
        return pid
    }

    init(
        projectName: String,
        cwd: String,
        runtime: AgentRuntime = .claudeCode,
        missionID: UUID = UUID(),
        resumeSessionId: String? = nil,
        initialPrompt: String? = nil
    ) {
        self.projectName = projectName
        self.cwd = cwd
        self.runtime = runtime
        self.missionID = missionID
        self.resumeSessionId = resumeSessionId
        self.sessionId = resumeSessionId
        self.initialPrompt = initialPrompt
    }

    var isSpawned: Bool { terminal != nil }

    /// Filter tier LIVE = `isSpawned` (a process runs: working, waiting, idle or
    /// paused; dormant and hibernated are out). Not `isLive`, which is the
    /// transcript-freshness flag the tick derives.
    ///
    /// ACTIVE = it needs the user, is rate-limited, or emitted output within the
    /// last `activeWindow`. Wider than the 6 s that drives the state dot, on
    /// purpose: a filter that dropped a tab six seconds after its last byte
    /// would flicker while an agent thinks between tool calls.
    nonisolated static let activeWindow: TimeInterval = 60

    /// claude hit the account usage cap on this session. Record the reset time
    /// (fallback +1h when claude stated none) so the cockpit can flag it + count
    /// down. onRateLimited lets the model raise an aggregate banner/notification.
    var onRateLimited: ((CockpitTab) -> Void)?

    // MARK: - Agent exit

    /// The agent process is gone but its login shell is still alive.
    ///
    /// This is the dangerous state: the pane looks exactly like a live session,
    /// the prompt from the agent is still painted on screen, and every keystroke
    /// now reaches zsh. Text meant for an agent — a path, a sentence with
    /// backticks, anything with `>` or `&&` — becomes a shell command.
    var agentExited = false
    /// Keystrokes are dropped until the user picks resume or shell. Set only
    /// when relaunching would be the wrong answer.
    var inputSuspended = false
    /// Exit instants inside the flap window, newest last.
    var recentAgentExits: [Date] = []

    /// Two exits this close together mean relaunching is not fixing anything —
    /// the agent is failing to start, or the machine cannot hold it. Relaunching
    /// again is the hibernate→respawn loop this codebase already refuses to build.
    static let agentFlapWindow: TimeInterval = 120
    static let agentFlapCount = 2
}
