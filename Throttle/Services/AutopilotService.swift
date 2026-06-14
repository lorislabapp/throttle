import Foundation

/// A single reversible file move. Archive operations record these so the
/// Autopilot ledger can undo precisely (the exact destination matters because
/// archiving renames on clash).
struct FileMove: Codable, Sendable, Hashable {
    let from: String   // original location
    let to: String     // where it was moved (archive)
}

/// **Throttle Autopilot** — keeps the user's Claude Code setup optimized
/// continuously and by default, system-wide. 100% local (nothing leaves the
/// Mac). Every action is reversible and recorded to a ledger with one-tap undo.
///
/// Balanced tier (the only auto set, per the user's choice):
///   1. ensure the global concise output-style is installed (claude terse
///      everywhere — terminal + Cockpit),
///   2. archive stale memory files (30+ days unused),
///   3. archive dead skills (installed but never invoked).
/// Dedup hoist and the transcript trimmer stay one-tap MANUAL — they rewrite
/// live content / their undo isn't yet equally bulletproof.
enum AutopilotService {

    // MARK: - Ledger model

    struct Entry: Codable, Identifiable, Sendable {
        enum Kind: String, Codable, Sendable { case outputStyle, statusline, memory, skills }
        let id: String
        let timestamp: Date
        let kind: Kind
        let summary: String
        var detail: String?      // "why this is better" — the commit-mode rationale
        var undone: Bool = false
        // undo payloads — only the field for this kind is populated:
        var previousOutputStyle: String?       // .outputStyle (nil = key was unset)
        var previousStatusLineJSON: String?    // .statusline
        var moves: [FileMove]?                 // .memory / .skills
    }

    // MARK: - Prefs

    private static let enabledKey = "autopilotEnabled"
    private static let lastRunKey = "autopilotLastRun"

    /// Master switch. Default ON — the user asked for system-wide-by-default.
    /// By default the only auto action is the concise output-style (provably
    /// safe + trivially reversible). Archiving is OPT-IN (below) because the
    /// "stale memory" / "dead skill" heuristics are too blunt to run unattended:
    /// a 30-day-untouched memory file is normal, and a never-invoked skill is
    /// often a situational one the user keeps on purpose.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Opt-in (default OFF). Even when on, index files are protected.
    static var archiveStaleMemory: Bool {
        get { UserDefaults.standard.bool(forKey: "autopilotArchiveMemory") }
        set { UserDefaults.standard.set(newValue, forKey: "autopilotArchiveMemory") }
    }
    /// Opt-in (default OFF). Even when on, skills referenced in any CLAUDE.md
    /// are protected.
    static var archiveDeadSkills: Bool {
        get { UserDefaults.standard.bool(forKey: "autopilotArchiveSkills") }
        set { UserDefaults.standard.set(newValue, forKey: "autopilotArchiveSkills") }
    }

    static var lastRun: Date? {
        UserDefaults.standard.object(forKey: lastRunKey) as? Date
    }

    // MARK: - Paths

    private static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/throttle-autopilot", isDirectory: true)
    }
    private static var ledgerFile: URL { dir.appendingPathComponent("ledger.json") }

    // MARK: - Run

    /// Run the balanced pass if enabled and not run within `minInterval`.
    /// Call this off-main on app launch. Returns entries created this pass.
    @discardableResult
    static func runIfDue(minInterval: TimeInterval = 22 * 3600) -> [Entry] {
        guard isEnabled else { return [] }
        if let last = lastRun, Date().timeIntervalSince(last) < minInterval { return [] }
        let made = runPass()
        UserDefaults.standard.set(Date(), forKey: lastRunKey)
        return made
    }

    /// Execute the balanced optimizations now, logging each reversible action.
    @discardableResult
    static func runPass() -> [Entry] {
        var made: [Entry] = []

        // 1) Concise output-style (system-wide). Install only if not already
        // ours AND the user hasn't picked their own style in the manager —
        // never override an explicit choice.
        if !OutputStyleManager.userOverride, !OutputStyleService.isInstalled() {
            if let res = try? OutputStyleService.install() {
                made.append(Entry(id: UUID().uuidString, timestamp: Date(), kind: .outputStyle,
                                  summary: "Installed concise output-style — claude is terse system-wide",
                                  detail: "Every session stays terse without losing Claude Code's engineering prompt — cuts repeated verbosity, never reduces reasoning or code quality.",
                                  previousOutputStyle: res.previousStyle))
            }
        }

        // 1b) Usage statusline — live headroom in every terminal session.
        if !StatuslineService.isInstalled() {
            if let res = try? StatuslineService.install() {
                made.append(Entry(id: UUID().uuidString, timestamp: Date(), kind: .statusline,
                                  summary: "Installed usage statusline — live headroom in every terminal session",
                                  detail: "Your cap %, reset and savings show in every terminal tab — you see saturation coming without opening the app.",
                                  previousStatusLineJSON: res.previousJSON))
            }
        }

        // 2) Orphaned-project memory — DEFAULT ON (provably safe: the project's
        //    working dir no longer exists, so the memory is unreachable).
        let orphaned = MemoryCleanupService.scanOrphaned()
        if !orphaned.isEmpty {
            let moves = MemoryCleanupService.archive(paths: orphaned)
            if !moves.isEmpty {
                made.append(Entry(id: UUID().uuidString, timestamp: Date(), kind: .memory,
                                  summary: "Archived \(moves.count) memory file\(moves.count == 1 ? "" : "s") from deleted projects",
                                  detail: "These belong to project folders that no longer exist — unreachable dead weight. Reversible from the archive.",
                                  moves: moves))
            }
        }

        // 2b) Archive stale memory — OPT-IN, and never index files (MEMORY.md).
        if archiveStaleMemory {
            let files = MemoryCleanupService.scan().files.filter { !isProtectedMemory($0.id) }
            if !files.isEmpty {
                let moves = MemoryCleanupService.archive(paths: files.map { $0.id })
                if !moves.isEmpty {
                    made.append(Entry(id: UUID().uuidString, timestamp: Date(), kind: .memory,
                                      summary: "Archived \(moves.count) stale memory file\(moves.count == 1 ? "" : "s")",
                                      detail: "Unused 30+ days — still reloaded every session until archived. The index (MEMORY.md) is always kept. Reversible.",
                                      moves: moves))
                }
            }
        }

        // 3) Archive dead skills — OPT-IN, and never skills referenced in a CLAUDE.md.
        if archiveDeadSkills {
            let keep = skillsReferencedInClaudeMd()
            let dead = SkillUsageService.scan().skills.filter { $0.dead && !keep.contains($0.name) }
            if !dead.isEmpty {
                var moves: [FileMove] = []
                for s in dead { if let m = try? SkillUsageService.archive(skillName: s.name) { moves.append(m) } }
                if !moves.isEmpty {
                    made.append(Entry(id: UUID().uuidString, timestamp: Date(), kind: .skills,
                                      summary: "Archived \(moves.count) dead skill\(moves.count == 1 ? "" : "s")",
                                      detail: "Never invoked across your transcripts and not referenced in any CLAUDE.md — their listing still costs prompt tokens. Reversible.",
                                      moves: moves))
                }
            }
        }

        if !made.isEmpty { append(made) }
        return made
    }

    // MARK: - Guards (so opt-in archiving can't catch the wrong things)

    /// Never archive a memory index — it's loaded every session and other files
    /// link to it.
    private static func isProtectedMemory(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return name == "memory.md" || name == "index.md" || name == "readme.md"
    }

    /// Skill names mentioned in any user-level CLAUDE.md are intentional even if
    /// never invoked in transcripts (they fire situationally) — keep them.
    private static func skillsReferencedInClaudeMd() -> Set<String> {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let docs = [
            home.appendingPathComponent(".claude/CLAUDE.md"),
            home.appendingPathComponent(".claude/CLAUDE-reference.md"),
            home.appendingPathComponent("CLAUDE.md"),
        ]
        var blob = ""
        for d in docs { if let t = try? String(contentsOf: d, encoding: .utf8) { blob += "\n" + t } }
        guard !blob.isEmpty else { return [] }
        let installed = SkillUsageService.scan().skills.map { $0.name }
        return Set(installed.filter { blob.contains($0) })
    }

    // MARK: - Undo

    /// Reverse one ledger entry. Idempotent.
    @discardableResult
    static func undo(_ id: String) -> Bool {
        var entries = loadRaw()
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return false }
        if entries[idx].undone { return true }
        let e = entries[idx]
        switch e.kind {
        case .outputStyle:
            try? OutputStyleService.remove(restorePreviousStyle: e.previousOutputStyle)
        case .statusline:
            try? StatuslineService.remove(restorePreviousJSON: e.previousStatusLineJSON)
        case .memory, .skills:
            let fm = FileManager.default
            for m in (e.moves ?? []) {
                let original = URL(fileURLWithPath: m.from)
                let archived = URL(fileURLWithPath: m.to)
                guard fm.fileExists(atPath: archived.path) else { continue }
                try? fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.moveItem(at: archived, to: original)
            }
        }
        entries[idx].undone = true
        save(entries)
        return true
    }

    static func undoAll() {
        for e in loadRaw() where !e.undone { _ = undo(e.id) }
    }

    /// Disable Autopilot, optionally rolling back everything it has done.
    static func disable(undoEverything: Bool) {
        isEnabled = false
        if undoEverything { undoAll() }
    }

    // MARK: - Ledger IO

    /// Newest first, for display.
    static func load() -> [Entry] { loadRaw().sorted { $0.timestamp > $1.timestamp } }

    private static func loadRaw() -> [Entry] {
        guard let data = try? Data(contentsOf: ledgerFile),
              let entries = try? Self.decoder.decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    private static func append(_ new: [Entry]) {
        var all = loadRaw(); all.append(contentsOf: new); save(all)
    }

    private static func save(_ entries: [Entry]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(entries) {
            try? data.write(to: ledgerFile, options: .atomic)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted]; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
