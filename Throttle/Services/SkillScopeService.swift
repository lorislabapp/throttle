import Foundation

/// Spatial Skill Scoping — the ACTION half of the Dead-Skill audit.
///
/// A global skill in `~/.claude/skills/<dir>/` loads its SKILL.md schema body
/// (~2–8 KB) into EVERY session, everywhere, paying that schema-token tax even on
/// projects that never use it. Claude Code's native nested discovery means a skill
/// living in `<repo>/.claude/skills/<dir>/` is only pulled into scope when the
/// agent actually works in that subtree. So physically relocating a heavy-but-
/// occasional skill into the one project that uses it removes its global cost
/// without deleting anything.
///
/// Doctrine: low-risk, REVERSIBLE file move (never a delete), opt-in, 1-click. We
/// refuse to clobber an existing target (the documented shadowing bug #44207 —
/// a project skill shadows the global one), and we VERIFY the move landed on disk
/// rather than assume. Caller should re-check `/context` to confirm the token drop.
enum SkillScopeService {

    enum ScopeError: LocalizedError {
        case sourceMissing, targetExists(String), notADirectory, moveFailed(String)
        var errorDescription: String? {
            switch self {
            case .sourceMissing:        return "That skill is no longer in ~/.claude/skills."
            case .targetExists(let p):  return "A skill already exists at \(p) — would shadow it (#44207). Left untouched."
            case .notADirectory:        return "Only directory skills (with SKILL.md) can be scoped."
            case .moveFailed(let m):    return "Move failed: \(m)"
            }
        }
    }

    /// A completed move, enough to reverse it precisely.
    struct Move: Codable, Sendable, Hashable {
        let skillDir: String   // folder name, e.g. "api-fuzzer"
        let from: String       // absolute path it left (global)
        let to: String         // absolute path it now lives (project-scoped)
    }

    private static var globalSkills: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills", isDirectory: true)
    }

    /// Move `~/.claude/skills/<skillDir>` → `<projectDir>/.claude/skills/<skillDir>`.
    /// Off-main caller. Reversible via `unscope(_:)`.
    static func scope(skillDir: String, toProject projectDir: String) throws -> Move {
        let fm = FileManager.default
        let src = globalSkills.appendingPathComponent(skillDir, isDirectory: true)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { throw ScopeError.sourceMissing }
        guard isDir.boolValue else { throw ScopeError.notADirectory }

        let destDir = URL(fileURLWithPath: projectDir, isDirectory: true)
            .appendingPathComponent(".claude/skills", isDirectory: true)
        let dest = destDir.appendingPathComponent(skillDir, isDirectory: true)
        if fm.fileExists(atPath: dest.path) { throw ScopeError.targetExists(dest.path) }

        do {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            try fm.moveItem(at: src, to: dest)
        } catch { throw ScopeError.moveFailed(error.localizedDescription) }

        // VERIFY (don't assume): gone from global, present in project.
        guard !fm.fileExists(atPath: src.path), fm.fileExists(atPath: dest.path) else {
            throw ScopeError.moveFailed("post-move verification failed")
        }
        return Move(skillDir: skillDir, from: src.path, to: dest.path)
    }

    /// Reverse a scope: move the skill back to `~/.claude/skills`. No-op-safe.
    @discardableResult
    static func unscope(_ move: Move) throws -> Bool {
        let fm = FileManager.default
        let from = URL(fileURLWithPath: move.to)
        let to = URL(fileURLWithPath: move.from)
        guard fm.fileExists(atPath: from.path) else { return false }
        if fm.fileExists(atPath: to.path) { throw ScopeError.targetExists(to.path) }
        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: from, to: to)
        return !fm.fileExists(atPath: from.path) && fm.fileExists(atPath: to.path)
    }

    /// A global skill that's only ever used in ONE project — the prime candidate
    /// to scope (move there) so it stops taxing every other session.
    struct Candidate: Sendable, Identifiable, Hashable {
        var id: String { skillDir }
        let skillDir: String     // global folder name
        let project: String      // the one cwd that uses it (real path from the transcript)
        let uses: Int
        let tokens: Int          // per-session schema tax removed by scoping
        var projectName: String { (project as NSString).lastPathComponent }
    }

    /// Scan transcripts (bounded) and return global skills used in exactly one
    /// project. Read-only. Uses the transcript's own `cwd` + `attributionSkill`
    /// fields (Claude Code writes both), so the target path is real, not a lossy
    /// decode of the project-dir name. Off-main caller.
    static func scopeCandidates(fileCap: Int = 4000) -> [Candidate] {
        let fm = FileManager.default
        let globalDirs = Set(((try? fm.contentsOfDirectory(atPath: globalSkills.path)) ?? [])
            .filter { !$0.hasPrefix(".") })
        guard !globalDirs.isEmpty else { return [] }

        // skill → (cwd → uses)
        var tally: [String: [String: Int]] = [:]
        let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        // Newest transcripts first, capped — recent usage is what matters.
        let files = (try? fm.contentsOfDirectory(at: projectsRoot,
                        includingPropertiesForKeys: [.contentModificationDateKey],
                        options: [.skipsHiddenFiles]).flatMap { dir -> [URL] in
                (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            }) ?? []
        let sorted = files.filter { $0.pathExtension == "jsonl" }
            .sorted { (mtime($0) ?? .distantPast) > (mtime($1) ?? .distantPast) }
            .prefix(fileCap)

        for url in sorted {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard line.contains("attributionSkill"),
                      let data = line.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let skill = o["attributionSkill"] as? String, !skill.isEmpty,
                      let cwd = o["cwd"] as? String, !cwd.isEmpty else { continue }
                tally[skill, default: [:]][cwd, default: 0] += 1
            }
        }

        var out: [Candidate] = []
        for (skill, byCwd) in tally {
            let used = byCwd.filter { $0.value > 0 }
            guard used.count == 1, let one = used.first else { continue }   // exactly one project
            guard globalDirs.contains(skill) else { continue }              // loaded globally (dir match = safe move)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: one.key, isDirectory: &isDir), isDir.boolValue else { continue }
            out.append(Candidate(skillDir: skill, project: one.key, uses: one.value,
                                 tokens: schemaTokenEstimate(skillDir: skill)))
        }
        return out.sorted { $0.tokens > $1.tokens }
    }

    private static func mtime(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Approx schema-token tax a global skill levies on EVERY session — its SKILL.md
    /// size / 4. Lets the UI show the per-session saving from scoping it.
    static func schemaTokenEstimate(skillDir: String) -> Int {
        let md = globalSkills.appendingPathComponent(skillDir, isDirectory: true)
            .appendingPathComponent("SKILL.md")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: md.path),
              let bytes = attrs[.size] as? Int else { return 0 }
        return max(1, bytes / 4)
    }
}
