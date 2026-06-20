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
    let startedAt = Date()

    /// LAZY: nil until the tab is first activated (memory-safe restore — a
    /// dormant restored tab costs nothing until you open it).
    private(set) var terminal: LocalProcessTerminalView?
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
    /// Hibernated = process subtree terminated to free RAM, resume-id kept.
    /// Distinct from a never-opened restored tab (both have terminal == nil).
    var isHibernated = false
    /// Resident memory of this session's process subtree (shell → claude → node).
    var ramBytes: UInt64 = 0
    /// The running claude session id, discovered at runtime — used for persistence.
    var sessionId: String?

    /// Rich session state for the rail dot — replaces the binary live/gray flicker.
    /// `working` covers BOTH claude streaming AND the user typing (lastActivityAt
    /// is bumped on keystrokes too), so the "claude is thinking before the first
    /// token" gap no longer reads as idle.
    enum SessionState { case dormant, hibernated, working, waiting, idle }
    var state: SessionState {
        if terminal == nil { return isHibernated ? .hibernated : .dormant }
        if needsInput { return .waiting }
        if Date().timeIntervalSince(lastActivityAt) < 6 { return .working }
        return .idle
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
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        term.startProcess(executable: shell, args: [], environment: env, execName: "-\(shellName)")
        CockpitTerminalTheme.apply(to: term)   // after spawn so the engine is live + a redraw is queued
        self.terminal = term

        let quoted = "'" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var cmd = "cd \(quoted) && clear && "
        // Prefer the persisted id; if it was lost, fall back to the newest
        // transcript in this project dir so we resume real context instead of
        // starting an empty session.
        let sid = sessionId ?? resumeSessionId
            ?? MultiCockpitModel.newestSession(cwd: cwd, since: .distantPast)?.id
        // Quote the id (M19): it's a transcript-derived value interpolated into a
        // shell command. Only accept a sane session-id shape, else start fresh.
        if let sid, sid.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            cmd += "claude --resume '\(sid)'"; self.sessionId = sid
        } else { cmd += "claude" }
        term.send(txt: cmd + "\n")
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
        terminal = nil
        ramBytes = 0
        isLive = false
        needsInput = false
        isHibernated = true
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
        case tabs, rail, mission
        var id: String { rawValue }
        var label: String { self == .tabs ? "Tabs" : (self == .rail ? "Rail" : "Overview") }
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
    var sortMode: SortMode = .manual

    private(set) var sessions: [CockpitTab] = []

    /// Sessions in display order. `.manual` keeps the drag-reordered order; the
    /// others sort a copy so the underlying drag order isn't mutated.
    var displaySessions: [CockpitTab] {
        switch sortMode {
        case .manual:  return sessions
        case .recent:  return sessions.sorted { $0.lastActivityAt > $1.lastActivityAt }
        case .cost:    return sessions.sorted { ($0.eur ?? -1) > ($1.eur ?? -1) }
        case .ram:     return sessions.sorted { $0.ramBytes > $1.ramBytes }
        case .name:    return sessions.sorted { $0.projectName.localizedCaseInsensitiveCompare($1.projectName) == .orderedAscending }
        case .waiting: return sessions.sorted {
            ($0.needsInput ? 1 : 0) != ($1.needsInput ? 1 : 0)
                ? ($0.needsInput ? 1 : 0) > ($1.needsInput ? 1 : 0)
                : $0.lastActivityAt > $1.lastActivityAt
        }
        }
    }

    // Don't auto-spawn a HIBERNATED tab (that's the hibernate→instant-respawn
    // loop, LR-H04). wake() clears isHibernated first, so explicit wakes still spawn.
    var activeID: UUID? { didSet {
        if let a = active, !a.isHibernated { a.ensureSpawned() }
        active?.clearAttention()
    } }
    var viewMode: ViewMode = .rail
    private(set) var machine: MemoryHealth = .unknown
    /// Count of sessions currently waiting on a question (for the header badge).
    var waitingCount: Int { sessions.filter { $0.needsInput }.count }

    private weak var appState: AppState?
    private var tick: Task<Void, Never>?
    private var focusObserver: NSObjectProtocol?

    var active: CockpitTab? { sessions.first { $0.id == activeID } ?? sessions.first }
    /// Opening another session would push the Mac past saturation.
    var gated: Bool { machine.critical }

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
                    if self.viewMode == .mission { self.viewMode = .tabs }
                }
            }
        }
        if sessions.isEmpty { restore() }   // bring back the working set (lazy)
        sampleMachine()
        tick?.cancel()
        tick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))   // 10s (was 5s): 29-tab fs walks were heavy on a swap-bound Mac
                self?.sampleMachine()
                self?.refreshStats()
                self?.sampleSessionRAM()
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
            let results: [(UUID, Double?, Int?, String?, Bool, String?)] = await Task.detached(priority: .utility) {
                items.map { item in
                    // since-gated discovery → liveness + the id we're allowed to adopt.
                    let recent = Self.newestSession(cwd: item.cwd, since: item.since)
                    let live = recent.map { Date().timeIntervalSince($0.mtime) < 12 } ?? false
                    // For COST, fall back to the persisted id / newest-ever transcript
                    // so a dormant restored tab with real history isn't shown "—" (M07).
                    let costId = recent?.id ?? item.sessionId
                        ?? Self.newestSession(cwd: item.cwd, since: .distantPast)?.id
                    guard let costId else { return (item.id, nil, nil, nil, live, recent?.id) }
                    let stats: (Double?, Int?, String?)? = try? db.read { d in
                        let eur = try? StatsDataService.cockpitSessionCostEUR(in: d, sessionId: costId)
                        let tok = try? StatsDataService.cockpitSessionTokens(in: d, sessionId: costId)
                        let split = (try? StatsDataService.cockpitModelSplitForSession(in: d, sessionId: costId)) ?? []
                        let model = split.max { $0.weightedTokens < $1.weightedTokens }
                            .flatMap { Self.modelName($0.tier) }
                        return (eur, tok, model)
                    }
                    return (item.id, stats?.0, stats?.1, stats?.2, live, recent?.id)
                }
            }.value
            guard let self else { return }
            var changed = false
            for (id, eur, tok, model, live, sid) in results {
                if let tab = self.sessions.first(where: { $0.id == id }) {
                    tab.eur = eur; tab.tokens = tok; tab.model = model; tab.isLive = live
                    // Only adopt a freshly-discovered id — NEVER clear to nil.
                    // A dormant restored tab has an old transcript mtime, so
                    // newestSession returns nil; clearing here would erase its
                    // persisted resume-id and lose the session on next restart.
                    if let sid, tab.sessionId != sid { tab.sessionId = sid; changed = true }
                }
            }
            if changed { self.persist() }   // keep saved resume-ids fresh
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
    }

    // MARK: - Persistence (memory-aware: restored tabs spawn lazily via resume)

    private static let persistKey = "cockpitOpenSessions"
    private struct Saved: Codable { let cwd: String; let name: String; let sessionId: String? }

    func persist() {
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
                }
            }
        }
    }

    @discardableResult
    func newSession(projectName: String, cwd: String) -> CockpitTab {
        let s = CockpitTab(projectName: projectName, cwd: cwd)
        wire(s)
        sessions.append(s)
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
        sessions.remove(at: idx)
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

    struct Binding { let pct: Int; let name: String; let reset: String; let estimate: Bool }

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
                return Binding(pct: b.1, name: b.0, reset: b.2.map(Self.hm) ?? "—", estimate: false)
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
                           reset: Self.hm(Date().addingTimeInterval(TimeInterval(b.2))), estimate: true)
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
