import AppKit
import SwiftTerm
import SwiftUI

/// One project session in the multi-cockpit: a real login-shell terminal
/// running in the project's cwd (the user runs `claude` in it, or it auto-
/// launches), plus the live metadata the decision layer shows. Per-session
/// cost/model are real-or-nil — never faked (the golden rule); they stay nil
/// until a data-linking pass wires them to StatsDataService.
@MainActor
@Observable
final class CockpitTab: Identifiable {
    let id = UUID()
    let projectName: String
    let cwd: String
    /// When this TAB was created (cockpit launch / new session) — used as the
    /// since-floor for transcript discovery. NOT the session's run time.
    let startedAt = Date()
    /// When the live `claude` PROCESS actually spawned — the real uptime. nil
    /// until spawned (a dormant restored tab has no running process, so it shows
    /// no uptime instead of the misleading shared "cockpit has been open Xm").
    var spawnedAt: Date?

    /// LAZY: nil until the tab is first activated (memory-safe restore — a
    /// dormant restored tab costs nothing until you open it).
    private(set) var terminal: LocalProcessTerminalView?
    /// LAZY side shell: a plain login zsh in the project's cwd, hosted in the
    /// split pane beside claude. nil until the user first opens the shell on this
    /// tab. NOT a claude subtree — just a shell (~10 MB), so cheap to keep.
    private(set) var shellTerminal: DroppableTerminalView?
    /// When restoring, resume the exact prior claude session.
    private let resumeSessionId: String?

    // Live metadata — nil = "not yet known", rendered as ≈/— (never invented).
    var model: String?
    var eur: Double?
    var tokens: Int?
    var isLive = false

    /// A question claude printed and is (best-effort) waiting on.
    struct Question: Identifiable { let id = UUID(); let text: String; let at = Date() }
    /// claude appears to be blocked on a prompt the user hasn't answered.
    var needsInput = false
    /// Recent detected questions (newest last), capped — the "don't lose it" feed.
    private(set) var questions: [Question] = []
    /// The latest question text, for inline display.
    var latestQuestion: String? { questions.last?.text }
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
    /// Set when claude prints a usage/rate-limit message; cleared once the stated
    /// reset time passes. Drives the `.rateLimited` state + cockpit banner.
    var rateLimitedUntil: Date?
    var isRateLimited: Bool { (rateLimitedUntil.map { $0 > Date() }) ?? false }
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

    /// Rich session state for the rail dot — replaces the binary live/gray flicker.
    /// `working` covers BOTH claude streaming AND the user typing (lastActivityAt
    /// is bumped on keystrokes too), so the "claude is thinking before the first
    /// token" gap no longer reads as idle.
    /// Frozen via SIGSTOP (reversible) to stop token burn without killing state —
    /// the circuit-breaker's safe, user-triggered half.
    var isPaused = false
    /// True when the freeze was applied by the crowding tier of auto-reclaim, NOT by
    /// the user. Auto-paused tabs resume instantly (SIGCONT) the moment they're
    /// focused, and may be escalated to hibernate under real memory pressure — neither
    /// happens to a tab the user paused by hand (explicit intent is preserved).
    var autoPaused = false

    enum SessionState { case dormant, hibernated, rateLimited, paused, working, waiting, idle }
    var state: SessionState {
        if terminal == nil { return isHibernated ? .hibernated : .dormant }
        if isPaused { return .paused }
        if isRateLimited { return .rateLimited }
        if needsInput { return .waiting }
        if Date().timeIntervalSince(lastActivityAt) < 6 { return .working }
        return .idle
    }

    /// Freeze/resume this session's process subtree (SIGSTOP/SIGCONT). No-op if
    /// not spawned. Reversible — never loses state, unlike hibernate (which kills).
    func pauseProcess() {
        guard let pid = shellPid, !isPaused else { return }
        SystemMemoryService.signalSubtree(rootPid: pid, signal: SIGSTOP)
        isPaused = true
    }
    func resumeProcess() {
        guard let pid = shellPid, isPaused else { return }
        SystemMemoryService.signalSubtree(rootPid: pid, signal: SIGCONT)
        isPaused = false
        autoPaused = false
    }

    /// PID of the session's login shell (root of its process subtree), if spawned.
    var shellPid: Int32? {
        guard let pid = terminal?.process?.shellPid, pid > 0 else { return nil }
        return pid
    }

    init(projectName: String, cwd: String, resumeSessionId: String? = nil) {
        self.projectName = projectName
        self.cwd = cwd
        self.resumeSessionId = resumeSessionId
        self.sessionId = resumeSessionId
    }

    var isSpawned: Bool { terminal != nil }

    /// Spawn the terminal on first activation: a login shell, then cd into the
    /// project and launch (or `--resume`) claude.
    func ensureSpawned() {
        guard terminal == nil else { return }
        isHibernated = false
        let term = DroppableTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        term.onActivity = { [weak self] in self?.lastActivityAt = Date() }
        term.onPrompt = { [weak self] q in self?.handlePrompt(q) }
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
            if self.isPaused { self.resumeProcess() } else { self.pauseProcess() }
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        let env = Self.terminalEnvironment()
        term.startProcess(executable: shell, args: [], environment: env, execName: "-\(shellName)")
        CockpitTerminalTheme.apply(to: term)   // after spawn so the engine is live + a redraw is queued
        // Low-memory mode: trim the scrollback (default 500) to 150 rows. A small
        // win on its own — the buffer is tiny next to the Node subtree — but it cuts
        // per-scroll redraw work, which is what actually stutters on the beta.
        let lowMem = UserDefaults.standard.bool(forKey: "throttleLowMemoryMode")
        if lowMem { term.changeScrollback(150) }
        self.terminal = term
        self.spawnedAt = Date()                // real process start → honest uptime

        let quoted = "'" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var cmd = "cd \(quoted) && clear && "
        // Spawn-tuning (16 GB constraint): Throttle owns the shell, so it can cap
        // the Node/V8 heap per session before launching claude. Opt-in — a cap set
        // too low crashes claude on a big context ("JS heap out of memory"), so it
        // ships OFF (0). --max-agents is likewise opt-in (verify your Claude Code
        // version supports the flag before enabling).
        let d = UserDefaults.standard
        // Low-memory mode supplies a safe default cap (3072 MB) when the user hasn't
        // set one — high enough not to OOM claude on a big context, low enough to
        // stop one runaway session eating the whole 16 GB.
        var heapMB = d.integer(forKey: "throttleNodeHeapCapMB")
        if heapMB <= 0, d.bool(forKey: "throttleLowMemoryMode") { heapMB = 3072 }
        if heapMB > 0 { cmd += "export NODE_OPTIONS='--max-old-space-size=\(heapMB)' && " }
        let maxAgents = d.integer(forKey: "throttleMaxAgents")
        let agentsFlag = maxAgents > 0 ? " --max-agents \(maxAgents)" : ""
        // Prefer the persisted id; if it was lost, fall back to the newest
        // transcript in this project dir so we resume real context instead of
        // starting an empty session.
        let sid = sessionId ?? resumeSessionId
            ?? MultiCockpitModel.newestSession(cwd: cwd, since: .distantPast)?.id
        // Quote the id (M19): it's a transcript-derived value interpolated into a
        // shell command. Only accept a sane session-id shape, else start fresh.
        if let sid, sid.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            cmd += "claude --resume '\(sid)'\(agentsFlag)"; self.sessionId = sid
        } else { cmd += "claude\(agentsFlag)" }
        term.send(txt: cmd + "\n")
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
        guard shellTerminal == nil else { return }
        let term = DroppableTerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 480))
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        let env = Self.terminalEnvironment()
        term.startProcess(executable: shell, args: [], environment: env, execName: "-\(shellName)")
        CockpitTerminalTheme.apply(to: term)
        if UserDefaults.standard.bool(forKey: "throttleLowMemoryMode") { term.changeScrollback(150) }
        shellTerminal = term
        // Drop the user straight into the project dir, matching the claude session's cwd.
        let quoted = "'" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        term.send(txt: "cd \(quoted) && clear\n")
    }

    /// Kill the side shell's process subtree and drop the terminal. Called on
    /// hibernate/close so it never leaks; reopening respawns fresh in the cwd.
    func terminateShell() {
        let pid = shellTerminal?.process?.shellPid
        shellTerminal?.send(txt: "\nexit\n")
        if let pid, pid > 0 { SystemMemoryService.killSubtree(rootPid: pid) }
        shellTerminal = nil
    }

    /// Exit claude (Ctrl-D) then the shell, then GUARANTEE the process subtree
    /// is gone. Cooperative exit alone can't kill a busy claude TUI (it ignores
    /// Ctrl-D mid-task), which orphaned shell→claude→node and leaked the RAM
    /// hibernate is meant to free. Capture the pid before the PTY ref drops.
    func terminate() {
        let pid = shellPid
        terminal?.send(txt: "\u{04}\nexit\n")
        if let pid { SystemMemoryService.killSubtree(rootPid: pid) }
    }

    /// Free this session's RAM: snapshot the resume-id, terminate the process
    /// subtree, drop the terminal → dormant. Reactivating respawns via
    /// `claude --resume` with full context. The tab stays in the rail.
    func hibernate() {
        guard terminal != nil else { return }
        if sessionId == nil {
            sessionId = MultiCockpitModel.newestSession(cwd: cwd, since: .distantPast)?.id
        }
        terminate()
        terminateShell()   // the side shell is per-tab RAM too; free it with the session
        terminal = nil
        ramBytes = 0
        isLive = false
        needsInput = false
        isPaused = false       // the SIGSTOP is moot once the subtree is killed; don't
        autoPaused = false     // leave a stale freeze flag on the hibernated (or woken) tab
        isHibernated = true
    }

    /// Restart this session in place to reclaim leaked/ballooned RAM: hibernate
    /// (kills the subtree, snapshots the resume-id) then immediately respawn via
    /// `claude --resume`, so the leaked node heap is freed but the conversation
    /// continues with full context. The user-triggered answer to a suspected leak.
    func restartInPlace() {
        guard terminal != nil else { return }
        hibernate()        // captures sessionId, kills subtree, terminal = nil
        ensureSpawned()    // respawns with --resume; clears isHibernated + leakSuspected
        leakSuspected = false
    }

    /// A detected question settled on the PTY. Flag attention + log it (deduped
    /// against the latest), then let the model decide whether to notify.
    func handlePrompt(_ q: String) {
        if questions.last?.text == q { return }
        questions.append(Question(text: q))
        if questions.count > 8 { questions.removeFirst(questions.count - 8) }
        needsInput = true
        onQuestion?(self, q)
    }

    /// claude hit the account usage cap on this session. Record the reset time
    /// (fallback +1h when claude stated none) so the cockpit can flag it + count
    /// down. onRateLimited lets the model raise an aggregate banner/notification.
    var onRateLimited: ((CockpitTab) -> Void)?
    func handleRateLimit(_ reset: Date?) {
        let until = reset ?? Date().addingTimeInterval(3600)
        // Only escalate on a fresh hit (not every repaint of the same banner).
        let wasLimited = isRateLimited
        rateLimitedUntil = until
        if !wasLimited { onRateLimited?(self) }
    }

    /// User is now looking at this session → clear the attention flag.
    func clearAttention() { needsInput = false }

    // MARK: - Timeline navigation (acts on this tab's live terminal)
    func jumpTurn(older: Bool) { (terminal as? DroppableTerminalView)?.scrollToTurn(older: older) }
    func scrollLive() { (terminal as? DroppableTerminalView)?.scrollToLive() }
}

/// Manages the set of cockpit sessions and the shared decision-layer data:
/// the global binding window (account-wide, from AppState) and machine memory
/// (from SystemMemoryService). The memory gate blocks opening a new session
/// when the Mac is saturated — directly serving the 16 GB constraint.
@MainActor
@Observable
final class MultiCockpitModel {
    /// Single shared instance — session lifetime must OUTLIVE the Cockpit window.
    /// Previously the model lived in the window's `@State`, so closing the window
    /// deallocated it and mass-killed all live `claude` sessions. As a singleton
    /// it survives window close: closing pauses the UI tick, never the PTYs.
    static let shared = MultiCockpitModel()

    enum ViewMode: String, CaseIterable, Identifiable {
        case dashboard, rail, tabs, mission
        var id: String { rawValue }
        var label: String {
            switch self {
            case .dashboard: return "Dashboard"
            case .tabs:      return "Tabs"
            case .rail:      return "Rail"
            case .mission:   return "Overview"
            }
        }
    }

    enum SortMode: String, CaseIterable, Identifiable {
        case manual, recent, cost, ram, name, waiting
        var id: String { rawValue }
        var label: String {
            switch self {
            case .manual:  return "Manual order"
            case .recent:  return "Last activity"
            case .cost:    return "Cost"
            case .ram:     return "Memory"
            case .name:    return "Name"
            case .waiting: return "Waiting first"
            }
        }
    }
    var sortMode: SortMode = .manual { didSet { if sortMode != oldValue { recomputeSortOrder() } } }

    private(set) var sessions: [CockpitTab] = []

    /// Cached display order (session ids). Recomputed only on an explicit trigger
    /// — sort-mode change, session add/remove, and the periodic tick — NOT on every
    /// `@Observable` mutation. Without this, sorting by "last activity" / cost / RAM
    /// re-sorts on every streamed byte and the rows thrash every few ms.
    private var sortedOrder: [UUID] = []

    /// Sessions in display order. `.manual` keeps the drag order; other modes map
    /// the live `sessions` onto the cached `sortedOrder` (stable between recomputes;
    /// ids not yet ranked fall to the end in their current order).
    var displaySessions: [CockpitTab] {
        guard sortMode != .manual else { return sessions }
        var rank: [UUID: Int] = [:]
        for (i, id) in sortedOrder.enumerated() { rank[id] = i }
        return sessions.enumerated().sorted {
            (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset)
        }.map(\.element)
    }

    /// Snapshot a fresh ordering for the current `sortMode` into `sortedOrder`.
    func recomputeSortOrder() {
        let ordered: [CockpitTab]
        switch sortMode {
        case .manual:  ordered = sessions
        case .recent:  ordered = sessions.sorted { $0.lastActivityAt > $1.lastActivityAt }
        case .cost:    ordered = sessions.sorted { ($0.eur ?? -1) > ($1.eur ?? -1) }
        case .ram:     ordered = sessions.sorted { $0.ramBytes > $1.ramBytes }
        case .name:    ordered = sessions.sorted { $0.projectName.localizedCaseInsensitiveCompare($1.projectName) == .orderedAscending }
        case .waiting: ordered = sessions.sorted {
            ($0.needsInput ? 1 : 0) != ($1.needsInput ? 1 : 0)
                ? ($0.needsInput ? 1 : 0) > ($1.needsInput ? 1 : 0)
                : $0.lastActivityAt > $1.lastActivityAt
        }
        }
        sortedOrder = ordered.map(\.id)
    }

    // Don't auto-spawn a HIBERNATED tab (that's the hibernate→instant-respawn
    // loop, LR-H04). wake() clears isHibernated first, so explicit wakes still spawn.
    var activeID: UUID? { didSet {
        if let a = active, !a.isHibernated {
            a.ensureSpawned()
            // An auto-paused tab wakes the instant you focus it: SIGCONT, zero tokens,
            // no --resume. A tab the USER paused stays frozen (their explicit intent).
            if a.autoPaused { a.resumeProcess() }
            if showShell { a.ensureShellSpawned() }   // keep the split's shell live for the new tab
        }
        active?.clearAttention()
    } }
    var viewMode: ViewMode = .dashboard   // the cover page is the landing view
    /// Split-pane side shell visible? Per-tab shell (each session's own zsh in its
    /// cwd), toggled with ⌘⇧T or the toolbar button. Off by default.
    var showShell = false
    /// Toggle the side shell; when opening, spawn the active tab's shell so the
    /// pane isn't blank. Spawning here (not in the view's updateNSView) keeps the
    /// @Observable mutation out of the render pass.
    func toggleShell() {
        showShell.toggle()
        if showShell, let a = active, !a.isHibernated { a.ensureShellSpawned() }
    }
    private(set) var machine: MemoryHealth = .unknown
    /// Count of sessions currently waiting on a question (for the header badge).
    var waitingCount: Int { sessions.filter { $0.needsInput }.count }

    /// cwds open in more than one SPAWNED tab — wasted RAM + tokens on the same
    /// project. (Cost reads identical across them because cost is per-project.)
    var duplicateCwds: Set<String> {
        let live = sessions.filter { $0.isSpawned }
        var counts: [String: Int] = [:]
        for t in live { counts[t.cwd, default: 0] += 1 }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    /// Consolidate: for each duplicated cwd, keep the most-recently-active spawned
    /// tab and hibernate the rest (resume-id preserved → wake-able, frees RAM).
    /// Never closes — nothing is lost. Doctrine: 1-click, user-initiated.
    func consolidateDuplicates() {
        for cwd in duplicateCwds {
            let dupes = sessions.filter { $0.isSpawned && $0.cwd == cwd }
                .sorted { $0.lastActivityAt > $1.lastActivityAt }
            for extra in dupes.dropFirst() { hibernate(extra.id) }
        }
    }

    private weak var appState: AppState?
    private var tick: Task<Void, Never>?
    private var focusObserver: NSObjectProtocol?
    private var commandObserver: NSObjectProtocol?

    var active: CockpitTab? { sessions.first { $0.id == activeID } ?? sessions.first }

    /// Freeze / unfreeze every live session (SIGSTOP/SIGCONT) — the reversible
    /// pause exposed to App Intents / Shortcuts. No-op on dormant tabs.
    func pauseAll()  { for s in sessions { s.pauseProcess() } }
    func resumeAll() { for s in sessions { s.resumeProcess() } }

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
    var pacingHint: PacingHint?
    private var pcLastPct: Double?
    private var pcLastAt: Date?
    private let pcLowPct = 80.0            // don't nag below 80% of the binding window
    private let pcEtaHorizon: TimeInterval = 30 * 60

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
            for s in targets { await self.drainThenPause(s) }
            self.recomputeSortOrder(); self.persist()
        }
    }

    /// Seconds left in the cancelable arming window (nil = not armed). Drives the banner.
    var autoPauseCountdown: Int?
    private var autoPauseTask: Task<Void, Never>?
    private var apLastPct: Double?
    private var apLastAt: Date?
    private let apThresholdPct = 95.0   // matches the design's `atcap` — 97% is too late, a runaway burns ~600k tok/min
    private let apEtaHorizon: TimeInterval = 5 * 60
    private let apGraceSeconds = 10

    private var autoPauseEnabled: Bool { UserDefaults.standard.bool(forKey: "throttleAutoPauseEnabled") }

    // Rules engine v1 — the concrete rule the planning docs kept asking for:
    // "auto-pause an Opus/Fable session past N tokens". Per-SESSION cap (not the
    // plan wall above): premium-model sessions that balloon are the #1 silent
    // spend, and pausing is reversible (SIGSTOP — resume keeps full context).
    private var opusCapEnabled: Bool { UserDefaults.standard.bool(forKey: "throttleOpusTokenCapEnabled") }
    private var opusCapTokens: Int {
        let v = UserDefaults.standard.integer(forKey: "throttleOpusTokenCapK")
        return (v > 0 ? v : 200) * 1_000    // default 200k
    }

    /// Cache-efficiency drop detector (hourly, notified at most once/24h): when
    /// today's prompt-cache hit rate falls ≥20 points under the 7-day baseline,
    /// something started busting the cache (hook churn, config edit, model swaps)
    /// and the plan is burning measurably faster. Complements CacheBustAnalyzer
    /// (which explains WHY) with a proactive "it's happening NOW" signal.
    private var lastEffCheck = Date.distantPast
    func evaluateCacheEfficiencyDrop() {
        guard Date().timeIntervalSince(lastEffCheck) > 3600 else { return }
        lastEffCheck = Date()
        guard let db = appState?.database else { return }
        Task.detached(priority: .utility) {
            guard let e24 = try? await db.read({ try StatsDataService.cacheEfficiency(in: $0, range: .last24h) }) ?? nil,
                  let e7 = try? await db.read({ try StatsDataService.cacheEfficiency(in: $0, range: .last7d) }) ?? nil,
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
            s.pauseProcess()
            CockpitNotifier.shared.notifyRule(
                title: "Session paused — \(s.projectName)",
                body: "\(model.capitalized) crossed \(cap / 1_000)k tokens (Opus-cap rule). Resume from the rail when you've checked it.")
        }
    }

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

    private func armAutoPause() {
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

    private func fireAutoPause() async {
        // Target the actual runaway, not every live session: if any session is flagged
        // as looping, freeze ONLY those; otherwise fall back to all live sessions. Keeps
        // the blast radius minimal (NotebookLM: don't freeze the whole fleet).
        let looping = sessions.filter { $0.isLive && !$0.isPaused && $0.loopSignal != nil }
        let targets = looping.isEmpty ? sessions.filter { $0.isLive && !$0.isPaused } : looping
        for s in targets { await drainThenPause(s) }
        autoPauseTask = nil
        autoPauseCountdown = nil
        apLastPct = nil; apLastAt = nil
    }

    /// State-aware drain (NotebookLM Q2): a bare SIGSTOP can land mid-flight — a held
    /// file lock, or a response in transit from Anthropic that arrives at a frozen
    /// client → corrupt state. We can't buffer the cloud socket (no-data-path-proxy
    /// doctrine), but we CAN avoid freezing during active work: pause only once the
    /// session's transcript has been quiet for a beat (no stream/tool-write in flight).
    /// Capped at 4 s so a relentlessly busy session is still paused — it already had
    /// the 10 s cancelable countdown.
    private func drainThenPause(_ s: CockpitTab) async {
        let cwd = s.cwd
        let deadline = Date().addingTimeInterval(4)
        var last = Self.newestSession(cwd: cwd, since: .distantPast)?.mtime
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            let now = Self.newestSession(cwd: cwd, since: .distantPast)?.mtime
            if let now, let last, now == last { break }   // 400 ms quiescent → safe window
            last = now
        }
        guard !s.isPaused else { return }
        s.pauseProcess()
    }
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
    private var autoHibIdleSeconds: TimeInterval { lowMemoryMode ? 5 * 60 : 15 * 60 }
    private var lastAutoHibernateAt = Date.distantPast
    private var pressureObserverRegistered = false

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

    // Two-tier reclaim. Crowding (many spawned tabs) is a PROACTIVE proxy for
    // impending pressure, not pressure itself — so crowding-only reclaim FREEZES
    // (SIGSTOP): token burn stops, resident pages go cold (the compressor swaps
    // them cheaply), and waking is instant with NO `claude --resume` — no transcript
    // re-send, no "resuming will consume your limits" prompt, zero tokens. Only real
    // `machine.critical` pressure escalates to hibernate (kill subtree → hard-free
    // RAM), where the wake-time token cost is justified by genuinely scarce memory.
    // This is the fix for "my tabs keep dying and resuming costs tokens" when the
    // Mac is merely crowded, not actually starved (see [[kevin-mac-memory-constraint]]).
    /// CPU share of a subtree, over the sampling window, above which the session is
    /// doing real work. An idle `claude` TUI and its MCP children sit near zero; a
    /// compile, a test run or an install sit far above. Deliberately low: wrongly
    /// reclaiming a working session costs the user their work, wrongly keeping an
    /// idle one costs some RAM until the next tick.
    private static let busyCPUPercent = 5.0

    /// A tool call still open after this long is presumed abandoned (claude crashed
    /// mid-tool, leaving a dangling tool_use as the transcript's last word). Without
    /// the bound, that tab would read as busy forever and never yield its RAM — worse
    /// than the bug this signal fixes, on a Mac already deep in swap.
    nonisolated static let maxToolCallProtection: TimeInterval = 30 * 60

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
        let live = sessions.filter { $0.isSpawned && !$0.isHibernated && !$0.isPaused }
        let pids = live.compactMap { $0.shellPid }
        guard !pids.isEmpty else { return }
        let cpu = SystemMemoryService.subtreeCPUSeconds(rootPids: pids)
        let now = Date()
        for tab in live {
            // Mid-tool beats every other signal: claude is working by definition, even
            // if the tool prints nothing and burns no CPU while it waits.
            if let sid = tab.sessionId,
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
            if total >= previous, (total - previous) / wall * 100 >= Self.busyCPUPercent {
                tab.lastActivityAt = now
            }
            tab.lastCPUSeconds = total
            tab.lastCPUSampleAt = now
        }
    }

    func autoHibernateIfPressured() {
        let spawnedCount = sessions.filter { $0.isSpawned && !$0.isHibernated }.count
        let crowded = maxLiveSessions > 0 && spawnedCount > maxLiveSessions
        guard autoHibernateEnabled, machine.critical || crowded else { return }
        // Must run before victim selection, including on the out-of-band pressure-rise
        // path — otherwise a build that has been silent for 5 minutes is a victim.
        refreshActivityFromCPU()
        // Debounce: at most once every 2 min so a sustained trigger doesn't churn
        // reclaim attempts every tick.
        guard Date().timeIntervalSince(lastAutoHibernateAt) > 120 else { return }
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
                $0.isSpawned && !$0.isHibernated && !$0.isRateLimited && $0.id != activeID
                && ($0.state == .idle || ($0.state == .paused && $0.autoPaused))
                && idleLongEnough($0)
            }
            guard !victims.isEmpty else { return }
            lastAutoHibernateAt = now
            let freed = victims.reduce(UInt64(0)) { $0 + $1.ramBytes }   // best-effort; RSS may be stale under quiet mode
            for v in victims { v.hibernate() }
            recomputeSortOrder()
            persist()
            CockpitNotifier.shared.notifyAutoHibernate(count: victims.count, freedBytes: freed)
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
            guard !victims.isEmpty else { return }
            lastAutoHibernateAt = now
            Task { @MainActor [weak self] in
                guard let self else { return }
                for v in victims {
                    await self.drainThenPause(v)
                    if v.isPaused { v.autoPaused = true }   // mark so focus auto-resumes it
                }
                let paused = victims.filter(\.autoPaused).count
                self.recomputeSortOrder()
                self.persist()
                CockpitNotifier.shared.notifyAutoPause(count: paused)
            }
        }
    }

    func start(appState: AppState) {
        self.appState = appState
        CockpitNotifier.shared.activate(appState: appState)
        if focusObserver == nil {
            focusObserver = NotificationCenter.default.addObserver(
                forName: .cockpitFocusSession, object: nil, queue: .main) { [weak self] note in
                guard let str = note.userInfo?["tab"] as? String, let id = UUID(uuidString: str) else { return }
                Task { @MainActor in
                    guard let self, self.sessions.contains(where: { $0.id == id }) else { return }
                    self.activeID = id
                    if self.viewMode == .mission { self.viewMode = .rail }
                }
            }
        }
        if commandObserver == nil {
            // Cross-process pause/resume from App Intents / Shortcuts (ThrottleCommandChannel).
            commandObserver = NotificationCenter.default.addObserver(
                forName: .throttleCommand, object: nil, queue: .main) { [weak self] note in
                guard let action = note.userInfo?["action"] as? String else { return }
                Task { @MainActor in
                    guard let self else { return }
                    if action == ThrottleAction.pauseAll.rawValue { self.pauseAll() }
                    else if action == ThrottleAction.resumeAll.rawValue { self.resumeAll() }
                }
            }
        }
        if sessions.isEmpty { restore() }   // bring back the working set (lazy)
        sessionsLoaded = true               // cockpit opened → `sessions` is canonical, safe to persist
        // React the instant pressure worsens to critical, not just on the next
        // 10–30 s tick (MEM-H01 / MEM-M03). Registered once.
        if !pressureObserverRegistered {
            pressureObserverRegistered = true
            MemoryPressureMonitor.shared.onPressureRise { [weak self] _ in self?.autoHibernateIfPressured() }
        }
        sampleMachine()
        tick?.cancel()
        tick = Task { [weak self] in
            while !Task.isCancelled {
                // Quiet mode: under memory pressure, tick 3× slower and skip the
                // heavy per-session RSS fs-walk so Throttle stops amplifying the
                // lag. The loop detector (in refreshStats) is the red line — it
                // keeps running, just less often. (NotebookLM hierarchy.)
                let quiet = MemoryPressureMonitor.shared.isQuiet
                try? await Task.sleep(for: .seconds(quiet ? 30 : 10))
                self?.sampleMachine()
                self?.refreshStats()
                self?.evaluateAutoPause()
                self?.evaluateOpusTokenCap()
                self?.evaluateCacheEfficiencyDrop()
                self?.evaluatePacing()             // soft cross-session pacing tier below auto-pause
                self?.autoHibernateIfPressured()   // MEM-H01: reclaim idle-session RAM under critical pressure
                if !quiet { self?.sampleSessionRAM() }
            }
        }
    }

    /// Wire each tab to its REAL claude session: the newest transcript in the
    /// tab's project dir (cwd → projects-dir encoding), then DB-query its € +
    /// tokens. Off-main; nil stays nil (never invented).
    func refreshStats() {
        guard let db = appState?.database else { return }
        let items = sessions.map { (id: $0.id, cwd: $0.cwd, since: $0.startedAt, sessionId: $0.sessionId) }
        guard !items.isEmpty else { return }
        Task { [weak self] in
            let results: [(UUID, Double?, Int?, String?, Bool, String?, LoopSignal?)] = await Task.detached(priority: .utility) {
                items.map { item in
                    // since-gated discovery → liveness + the id we're allowed to adopt.
                    let recent = Self.newestSession(cwd: item.cwd, since: item.since)
                    let live = recent.map { Date().timeIntervalSince($0.mtime) < 12 } ?? false
                    // Runaway-loop check on the LIVE transcript only (cheap tail read).
                    let loop = (live ? recent?.id : nil).flatMap { LoopDetectorService.detect(cwd: item.cwd, sessionId: $0) }
                    // For COST, fall back to the persisted id / newest-ever transcript
                    // so a dormant restored tab with real history isn't shown "—" (M07).
                    let costId = recent?.id ?? item.sessionId
                        ?? Self.newestSession(cwd: item.cwd, since: .distantPast)?.id
                    guard let costId else { return (item.id, nil, nil, nil, live, recent?.id, loop) }
                    let stats: (Double?, Int?, String?)? = try? db.read { d in
                        let eur = try? StatsDataService.cockpitSessionCostEUR(in: d, sessionId: costId)
                        let tok = try? StatsDataService.cockpitSessionTokens(in: d, sessionId: costId)
                        let split = (try? StatsDataService.cockpitModelSplitForSession(in: d, sessionId: costId)) ?? []
                        let model = split.max { $0.weightedTokens < $1.weightedTokens }
                            .flatMap { Self.modelName($0.tier) }
                        return (eur, tok, model)
                    }
                    return (item.id, stats?.0, stats?.1, stats?.2, live, recent?.id, loop)
                }
            }.value
            guard let self else { return }
            var changed = false
            for (id, eur, tok, model, live, sid, loop) in results {
                if let tab = self.sessions.first(where: { $0.id == id }) {
                    // Mid-session model swap = orphaned prompt cache (caches are
                    // per-model). On a big context this makes the swap COSTLIER
                    // than staying — verified against Anthropic's cache docs
                    // (deep research 2026-07-14). Warn once per swap; ≥30k tokens
                    // so a fresh session picking its model doesn't false-fire.
                    if let old = tab.lastSeenModel, let new = model, old != new,
                       live, (tok ?? 0) > 30_000 {
                        CockpitNotifier.shared.notifyRule(
                            title: "Model swap mid-session — \(tab.projectName)",
                            body: "\(old) → \(new) with \((tok ?? 0) / 1_000)k tokens of context: the prompt cache is per-model, so this rebuilds it from scratch (often pricier than staying). Prefer finishing the task, or offload to the box.")
                    }
                    if model != nil { tab.lastSeenModel = model }
                    tab.eur = eur; tab.tokens = tok; tab.model = model; tab.isLive = live; tab.loopSignal = loop
                    // Only adopt a freshly-discovered id — NEVER clear to nil.
                    // A dormant restored tab has an old transcript mtime, so
                    // newestSession returns nil; clearing here would erase its
                    // persisted resume-id and lose the session on next restart.
                    if let sid, tab.sessionId != sid { tab.sessionId = sid; changed = true }
                }
            }
            if changed { self.persist() }   // keep saved resume-ids fresh
            self.recomputeSortOrder()        // refresh sort order on the tick, not per-byte
        }
    }

    private nonisolated static func modelName(_ tier: ModelTier) -> String? {
        switch tier {
        case .opus:   return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku:  return "Haiku"
        case .other:  return nil
        }
    }

    /// Claude Code's project-dir encoding: EVERY non-alphanumeric character in
    /// the absolute cwd becomes `-` (so `/`, spaces, dots, accents all collapse
    /// to `-`). Matching this exactly is critical — "Opnsens Prod" → "…-Opnsens
    /// -Prod", not "…-Opnsens Prod". A mismatch unlinks the session and loses it.
    nonisolated static func claudeProjectDirName(_ cwd: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String(cwd.map { allowed.contains($0) ? $0 : "-" })
    }

    /// The sessionId of the tab's running claude: newest `.jsonl` in
    /// `~/.claude/projects/<encoded cwd>/`, modified at/after the tab started.
    nonisolated static func newestSession(cwd: String, since: Date) -> (id: String, mtime: Date)? {
        let encoded = claudeProjectDirName(cwd)
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(encoded)", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let jsonls = files.filter { $0.pathExtension == "jsonl" }
        let newest = jsonls.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let dbb = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < dbb
        }
        guard let newest,
              let mod = try? newest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              mod >= since.addingTimeInterval(-5) else { return nil }
        return (newest.deletingPathExtension().lastPathComponent, mod)
    }

    /// Window closed (NOT app quit): pause the sampling tick + persist, but KEEP
    /// every session running in the background. Reopening the window re-arms via
    /// start(). This is the half of the C01 fix that stops window-close from
    /// killing live sessions.
    func pause() {
        persist()
        tick?.cancel(); tick = nil
    }

    /// Full teardown — app quit only. Hard-kills each session's process subtree.
    func stop() {
        persist()                            // remember the working set first
        tick?.cancel(); tick = nil
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver); self.focusObserver = nil }
        if let commandObserver { NotificationCenter.default.removeObserver(commandObserver); self.commandObserver = nil }
        for s in sessions { s.terminate() }
        sessions.removeAll()
    }

    /// Wire a tab's question callback: a question in a HIDDEN session raises a
    /// local notification (you may be in another window); the active session
    /// already shows the prompt, so no notification — just the in-app badge.
    private func wire(_ tab: CockpitTab) {
        tab.onQuestion = { [weak self] tab, q in
            guard let self, tab.id != self.activeID else { return }
            CockpitNotifier.shared.notifyWaiting(project: tab.projectName, question: q, tabID: tab.id)
        }
        tab.onRateLimited = { tab in
            CockpitNotifier.shared.notifyRateLimited(
                project: tab.projectName, until: tab.rateLimitedUntil, tabID: tab.id)
        }
    }

    /// Sessions currently blocked by the account cap, soonest-reset first.
    var rateLimitedSessions: [CockpitTab] {
        sessions.filter { $0.isRateLimited }
            .sorted { ($0.rateLimitedUntil ?? .distantFuture) < ($1.rateLimitedUntil ?? .distantFuture) }
    }
    /// The earliest reset among blocked sessions (for the aggregate banner).
    var soonestRateLimitReset: Date? { rateLimitedSessions.first?.rateLimitedUntil }

    /// Sessions the loop detector flagged as cycling without progress.
    var loopSessions: [CockpitTab] { sessions.filter { $0.loopSignal != nil } }
    /// Spawned sessions whose subtree RSS ballooned past the leak threshold (#4953).
    var leakSessions: [CockpitTab] { sessions.filter { $0.leakSuspected && $0.isSpawned } }

    // MARK: - Persistence (memory-aware: restored tabs spawn lazily via resume)

    private static let persistKey = "cockpitOpenSessions"
    private struct Saved: Codable { let cwd: String; let name: String; let sessionId: String? }

    /// True once restore() has run or a session was added — i.e. `sessions` is the
    /// canonical working set. Until then, persisting would write garbage.
    private var sessionsLoaded = false

    func persist() {
        // NEVER overwrite the saved working set with an empty list we never loaded
        // (e.g. the app launched but the cockpit was never opened, so restore()
        // didn't run). That would wipe the user's sessions on quit.
        guard sessionsLoaded else { return }
        let saved = sessions.map { Saved(cwd: $0.cwd, name: $0.projectName, sessionId: $0.sessionId) }
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.persistKey)
        }
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.persistKey),
              let saved = try? JSONDecoder().decode([Saved].self, from: data), !saved.isEmpty else { return }
        let fm = FileManager.default
        for item in saved {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.cwd, isDirectory: &isDir), isDir.boolValue else { continue }
            let tab = CockpitTab(projectName: item.name, cwd: item.cwd, resumeSessionId: item.sessionId)
            wire(tab)
            sessions.append(tab)
        }
        recomputeSortOrder()
        activeID = sessions.first?.id   // spawns ONLY the active tab (others dormant)
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
        let pairs: [(UUID, Int32)] = sessions.compactMap { tab in tab.shellPid.map { (tab.id, $0) } }
        guard !pairs.isEmpty else { return }
        let pids = pairs.map { $0.1 }
        Task { [weak self] in
            let map = await Task.detached(priority: .utility) { SystemMemoryService.subtreeRSS(rootPids: pids) }.value
            guard let self else { return }
            for (id, pid) in pairs {
                if let bytes = map[pid], let tab = self.sessions.first(where: { $0.id == id }) {
                    tab.ramBytes = bytes
                    // Leak heuristic (#4953): Claude Code's node process can grow
                    // unbounded on long sessions/subagents. Flag a ballooned subtree
                    // so the UI can nudge a restart-in-place (reclaims the leaked
                    // heap, keeps context via --resume) — advisory, never automatic.
                    tab.leakSuspected = bytes > 3_000_000_000
                }
            }
        }
    }

    @discardableResult
    func newSession(projectName: String, cwd: String) -> CockpitTab {
        let s = CockpitTab(projectName: projectName, cwd: cwd)
        wire(s)
        sessions.append(s)
        recomputeSortOrder()
        activeID = s.id   // didSet → ensureSpawned
        persist()
        return s
    }

    /// Hibernate a session to free RAM. If it's the active one, move focus to
    /// another live tab first (so the terminal area isn't left blank).
    func hibernate(_ id: UUID) {
        guard let tab = sessions.first(where: { $0.id == id }), tab.isSpawned else { return }
        if activeID == id {
            // Move focus to another LIVE tab, or to nil (placeholder) if none —
            // never keep focus on the tab we're about to hibernate (respawn loop).
            activeID = sessions.first(where: { $0.id != id && $0.isSpawned })?.id
        }
        tab.hibernate()
        persist()
    }

    /// Wake a hibernated session: clear the hibernated flag (so the didSet guard
    /// allows the spawn), make it active → ensureSpawned respawns + `--resume`s.
    func wake(_ id: UUID) {
        sessions.first(where: { $0.id == id })?.isHibernated = false
        activeID = id
    }

    /// Re-apply the current terminal preset to every live session (theme switch).
    func restyleTerminals() {
        for tab in sessions { if let t = tab.terminal { CockpitTerminalTheme.apply(to: t, setFont: false) } }
    }

    /// Nav helpers routed to the active session's terminal.
    func jumpTurn(older: Bool) { active?.jumpTurn(older: older) }
    func scrollLive() { active?.scrollLive() }

    func close(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].terminate()
        sessions[idx].terminateShell()   // don't orphan the side shell's process
        sessions.remove(at: idx)
        recomputeSortOrder()
        if activeID == id { activeID = sessions.first?.id }
        persist()
    }

    /// Drag-reorder: move `dragged` to where `target` sits. Persists the order.
    func move(dragged: UUID, onto target: UUID) {
        guard dragged != target,
              let from = sessions.firstIndex(where: { $0.id == dragged }) else { return }
        let item = sessions.remove(at: from)
        let to = sessions.firstIndex(where: { $0.id == target }) ?? sessions.count
        sessions.insert(item, at: to)
        persist()
    }

    // MARK: - Global binding (account-wide, shared by all sessions)

    struct Binding { let pct: Int; let name: String; let reset: String; let estimate: Bool; let resetInSeconds: Int64? }

    /// "2h 14m" style countdown for the binding reset.
    static func countdown(_ seconds: Int64) -> String {
        guard seconds > 0 else { return "now" }
        let h = seconds / 3600, m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    var binding: Binding? {
        guard let appState else { return nil }
        // Only claim EXACT when the server snapshot is actually fresh — otherwise
        // degrade to the local estimate (≈), same as the menu-bar dropdown. A
        // stale exact value labelled EXACT violates the golden rule.
        if let ex = appState.exactSnapshot, ex.isFresh() {
            let ws: [(String, Int, Date?)] = [
                ("Session", ex.fiveHour.utilization, ex.fiveHour.resetsAt),
                ("Weekly", ex.sevenDay.utilization, ex.sevenDay.resetsAt),
                ("Weekly · Sonnet", ex.sevenDaySonnet.utilization, ex.sevenDaySonnet.resetsAt),
            ]
            if let b = ws.max(by: { $0.1 < $1.1 }) {
                return Binding(pct: b.1, name: b.0, reset: b.2.map(Self.hm) ?? "—", estimate: false,
                               resetInSeconds: b.2.map { Int64($0.timeIntervalSinceNow) })
            }
        }
        let snap = appState.snapshot
        let cands: [(String, Double, Int64)] = [
            ("Session", snap.session5h.percentUsed ?? -1, snap.session5h.resetInSeconds),
            ("Weekly", snap.weeklyAll.percentUsed ?? -1, snap.weeklyAll.resetInSeconds),
            ("Weekly · Sonnet", snap.weeklySonnet.percentUsed ?? -1, snap.weeklySonnet.resetInSeconds),
        ].filter { $0.1 >= 0 }
        if let b = cands.max(by: { $0.1 < $1.1 }) {
            return Binding(pct: Int((b.1 * 100).rounded()), name: b.0,
                           reset: Self.hm(Date().addingTimeInterval(TimeInterval(b.2))), estimate: true,
                           resetInSeconds: b.2)
        }
        return nil
    }

    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
    static func hm(_ d: Date) -> String {
        return hmFormatter.string(from: d)
    }

    // MARK: - Project picker (existing projects only)

    struct Project: Identifiable, Hashable { let id = UUID(); let name: String; let cwd: String }

    /// Distinct project working dirs from past sessions whose cwd still exists,
    /// most-recent first. Light: reads ≤64 KB of one transcript per project.
    func recentProjects(limit: Int = 12) -> [Project] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let sorted = dirs.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        let home = fm.homeDirectoryForCurrentUser.path
        var seen = Set<String>()
        var out: [Project] = []
        for dir in sorted {
            guard let cwd = Self.projectCwd(dir), !seen.contains(cwd) else { continue }
            // Skip the home dir itself and obvious non-projects (temp/hidden).
            guard cwd != home, !cwd.hasPrefix("/private/"), !cwd.hasPrefix("/tmp"),
                  !(cwd as NSString).lastPathComponent.hasPrefix(".") else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else { continue }
            seen.insert(cwd)
            out.append(Project(name: (cwd as NSString).lastPathComponent, cwd: cwd))
            if out.count >= limit { break }
        }
        return out
    }

    private static func projectCwd(_ projectDir: URL) -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil) else { return nil }
        for url in entries.filter({ $0.pathExtension == "jsonl" }).prefix(2) {
            guard let fh = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? fh.close() }
            let chunk = (try? fh.read(upToCount: 65_536)) ?? Data()
            guard let text = String(data: chunk, encoding: .utf8),
                  let r = text.range(of: "\"cwd\":\"") ?? text.range(of: "\"cwd\": \"") else { continue }
            let rest = text[r.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            return String(rest[..<end]).replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "\\\\", with: "\\")
        }
        return nil
    }
}
