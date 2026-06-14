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
    let terminal: LocalProcessTerminalView
    let startedAt = Date()

    // Live metadata — nil = "not yet known", rendered as ≈/— (never invented).
    var model: String?
    var eur: Double?
    var tokens: Int?

    init(projectName: String, cwd: String, autostartClaude: Bool = true) {
        self.projectName = projectName
        self.cwd = cwd
        let term = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        // Login shell (execName "-…") so the user's full PATH loads and `claude`
        // resolves — a Finder-launched GUI app otherwise gets a minimal PATH.
        term.startProcess(executable: shell, args: [], environment: env, execName: "-\(shellName)")
        self.terminal = term

        // cd into the project, then (optionally) start claude.
        let quoted = "'" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var cmd = "cd \(quoted) && clear"
        if autostartClaude { cmd += " && claude" }
        term.send(txt: cmd + "\n")
    }

    /// Exit claude (Ctrl-D) then the shell, releasing the PTY.
    func terminate() { terminal.send(txt: "\u{04}\nexit\n") }
}

/// Manages the set of cockpit sessions and the shared decision-layer data:
/// the global binding window (account-wide, from AppState) and machine memory
/// (from SystemMemoryService). The memory gate blocks opening a new session
/// when the Mac is saturated — directly serving the 16 GB constraint.
@MainActor
@Observable
final class MultiCockpitModel {
    enum ViewMode: String, CaseIterable, Identifiable {
        case tabs, rail, mission
        var id: String { rawValue }
        var label: String { self == .tabs ? "Tabs" : (self == .rail ? "Rail" : "Overview") }
    }

    private(set) var sessions: [CockpitTab] = []
    var activeID: UUID?
    var viewMode: ViewMode = .rail
    private(set) var machine: MemoryHealth = .unknown

    private weak var appState: AppState?
    private var tick: Task<Void, Never>?

    var active: CockpitTab? { sessions.first { $0.id == activeID } ?? sessions.first }
    /// Opening another session would push the Mac past saturation.
    var gated: Bool { machine.critical }

    func start(appState: AppState) {
        self.appState = appState
        sampleMachine()
        tick?.cancel()
        tick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.sampleMachine()
                self?.refreshStats()
            }
        }
    }

    /// Wire each tab to its REAL claude session: the newest transcript in the
    /// tab's project dir (cwd → projects-dir encoding), then DB-query its € +
    /// tokens. Off-main; nil stays nil (never invented).
    func refreshStats() {
        guard let db = appState?.database else { return }
        let items = sessions.map { (id: $0.id, cwd: $0.cwd, since: $0.startedAt) }
        guard !items.isEmpty else { return }
        Task { [weak self] in
            let results: [(UUID, Double?, Int?)] = await Task.detached(priority: .utility) {
                items.map { item in
                    guard let sid = Self.newestSessionId(cwd: item.cwd, since: item.since) else { return (item.id, nil, nil) }
                    let stats: (Double?, Int?)? = try? db.read { d in
                        (try? StatsDataService.cockpitSessionCostEUR(in: d, sessionId: sid),
                         try? StatsDataService.cockpitSessionTokens(in: d, sessionId: sid))
                    }
                    return (item.id, stats?.0, stats?.1)
                }
            }.value
            guard let self else { return }
            for (id, eur, tok) in results {
                if let tab = self.sessions.first(where: { $0.id == id }) { tab.eur = eur; tab.tokens = tok }
            }
        }
    }

    /// The sessionId of the tab's running claude: newest `.jsonl` in
    /// `~/.claude/projects/<cwd with / → ->/`, modified at/after the tab started.
    nonisolated static func newestSessionId(cwd: String, since: Date) -> String? {
        let encoded = cwd.replacingOccurrences(of: "/", with: "-")
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
        return newest.deletingPathExtension().lastPathComponent
    }

    func stop() {
        tick?.cancel(); tick = nil
        for s in sessions { s.terminate() }
        sessions.removeAll()
    }

    func sampleMachine() {
        Task { [weak self] in
            let h = await Task.detached(priority: .utility) { SystemMemoryService.sample() }.value
            self?.machine = h
        }
    }

    @discardableResult
    func newSession(projectName: String, cwd: String) -> CockpitTab {
        let s = CockpitTab(projectName: projectName, cwd: cwd)
        sessions.append(s)
        activeID = s.id
        return s
    }

    func close(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].terminate()
        sessions.remove(at: idx)
        if activeID == id { activeID = sessions.first?.id }
    }

    // MARK: - Global binding (account-wide, shared by all sessions)

    struct Binding { let pct: Int; let name: String; let reset: String; let estimate: Bool }

    var binding: Binding? {
        guard let appState else { return nil }
        if let ex = appState.exactSnapshot {
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

    static func hm(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f.string(from: d)
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
        var seen = Set<String>()
        var out: [Project] = []
        for dir in sorted {
            guard let cwd = Self.projectCwd(dir), !seen.contains(cwd) else { continue }
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
