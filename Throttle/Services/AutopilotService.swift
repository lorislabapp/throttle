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
        enum Kind: String, Codable, Sendable { case outputStyle, memory, skills }
        let id: String
        let timestamp: Date
        let kind: Kind
        let summary: String
        var undone: Bool = false
        // undo payloads — only the field for this kind is populated:
        var previousOutputStyle: String?   // .outputStyle (nil = key was unset)
        var moves: [FileMove]?             // .memory / .skills
    }

    // MARK: - Prefs

    private static let enabledKey = "autopilotEnabled"
    private static let lastRunKey = "autopilotLastRun"

    /// Master switch. Default ON — the user asked for system-wide-by-default;
    /// every action it takes is reversible and logged.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
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

        // 1) Concise output-style (system-wide). Install only if not already ours.
        if !OutputStyleService.isInstalled() {
            if let res = try? OutputStyleService.install() {
                made.append(Entry(id: UUID().uuidString, timestamp: Date(), kind: .outputStyle,
                                  summary: "Installed concise output-style — claude is terse system-wide",
                                  previousOutputStyle: res.previousStyle))
            }
        }

        // 2) Archive stale memory (30+ days unused). StaleMemory.id is the path.
        let mem = MemoryCleanupService.scan()
        if !mem.files.isEmpty {
            let moves = MemoryCleanupService.archive(paths: mem.files.map { $0.id })
            if !moves.isEmpty {
                made.append(Entry(id: UUID().uuidString, timestamp: Date(), kind: .memory,
                                  summary: "Archived \(moves.count) stale memory file\(moves.count == 1 ? "" : "s")",
                                  moves: moves))
            }
        }

        // 3) Archive dead skills (installed, never invoked).
        let dead = SkillUsageService.scan().skills.filter { $0.dead }
        if !dead.isEmpty {
            var moves: [FileMove] = []
            for s in dead { if let m = try? SkillUsageService.archive(skillName: s.name) { moves.append(m) } }
            if !moves.isEmpty {
                made.append(Entry(id: UUID().uuidString, timestamp: Date(), kind: .skills,
                                  summary: "Archived \(moves.count) dead skill\(moves.count == 1 ? "" : "s")",
                                  moves: moves))
            }
        }

        if !made.isEmpty { append(made) }
        return made
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
