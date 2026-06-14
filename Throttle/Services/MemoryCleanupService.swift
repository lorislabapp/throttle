import Foundation

/// Finds stale Claude Code memory files — `~/.claude/projects/*/memory/*.md`
/// not touched in 30+ days. Claude Code reloads these every session, so stale
/// ones burn tokens for context nobody uses. v1 detects + quantifies; it never
/// deletes (purge-with-confirm is a later phase).
struct StaleMemory: Sendable, Identifiable {
    let id: String        // full path
    let name: String      // file name
    let project: String   // decoded project name
    let ageDays: Int
    let tokens: Int        // ≈ load cost
}

struct MemoryReport: Sendable {
    let files: [StaleMemory]
    var totalTokens: Int { files.reduce(0) { $0 + $1.tokens } }
    static let empty = MemoryReport(files: [])
}

enum MemoryCleanupService {
    static let staleDays = 30

    static func scan(now: Date = Date()) -> MemoryReport {
        let fm = FileManager.default
        let projectsDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        guard let projects = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return .empty
        }
        var stale: [StaleMemory] = []
        let cutoff = TimeInterval(staleDays) * 86_400

        for proj in projects.prefix(120) {
            let memDir = proj.appendingPathComponent("memory", isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: memDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            let projectName = decodeName(proj.lastPathComponent)
            for f in files where f.pathExtension == "md" {
                guard let vals = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let mtime = vals.contentModificationDate else { continue }
                let age = now.timeIntervalSince(mtime)
                guard age > cutoff else { continue }
                let size = vals.fileSize ?? 0
                stale.append(StaleMemory(
                    id: f.path, name: f.lastPathComponent, project: projectName,
                    ageDays: Int(age / 86_400), tokens: max(1, (size * 250) / 1024)
                ))
            }
        }
        return MemoryReport(files: stale.sorted { $0.tokens > $1.tokens })
    }

    /// Provably-safe target for auto-archiving: memory files belonging to a
    /// project whose working directory **no longer exists** (the project was
    /// deleted). The real cwd is read from the project's own transcript (no
    /// lossy dir-name decoding), reading at most 64 KB so it stays light on a
    /// memory-constrained Mac. Guards: only judge projects under the user's
    /// home (so an unmounted external volume isn't mistaken for deleted), and
    /// never index files.
    static func scanOrphaned() -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let projectsDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        guard let projects = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else { return [] }

        var orphaned: [String] = []
        for proj in projects {
            let memDir = proj.appendingPathComponent("memory", isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: memDir, includingPropertiesForKeys: nil),
                  files.contains(where: { $0.pathExtension == "md" }) else { continue }
            guard let cwd = projectCwd(proj), cwd.hasPrefix(home) else { continue }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue { continue } // still exists → keep
            for f in files where f.pathExtension == "md" && f.lastPathComponent.lowercased() != "memory.md" {
                orphaned.append(f.path)
            }
        }
        return orphaned
    }

    /// Read a project's real `cwd` from one of its transcripts (first 64 KB of
    /// up to 3 files). Returns nil if undetermined — callers then leave it alone.
    private static func projectCwd(_ projectDir: URL) -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil) else { return nil }
        for url in entries.filter({ $0.pathExtension == "jsonl" }).prefix(3) {
            guard let fh = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? fh.close() }
            let chunk = (try? fh.read(upToCount: 65_536)) ?? Data()
            guard let text = String(data: chunk, encoding: .utf8),
                  let r = text.range(of: "\"cwd\":\"") ?? text.range(of: "\"cwd\": \"") else { continue }
            let rest = text[r.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            return String(rest[..<end])
                .replacingOccurrences(of: "\\/", with: "/")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return nil
    }

    /// Archive stale memory files by MOVING them to ~/.claude/memory-archive
    /// (reversible — never deletes), preserving the project sub-path. Returns
    /// the exact moves performed (from→to) so a caller can undo precisely.
    @discardableResult
    static func archive(paths: [String]) -> [FileMove] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let projects = home.appendingPathComponent(".claude/projects").path
        let base = home.appendingPathComponent(".claude/memory-archive", isDirectory: true)
        var moves: [FileMove] = []
        for p in paths {
            let src = URL(fileURLWithPath: p)
            let rel = p.hasPrefix(projects + "/") ? String(p.dropFirst(projects.count + 1)) : src.lastPathComponent
            var dest = base.appendingPathComponent(rel)
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                dest = dest.deletingLastPathComponent()
                    .appendingPathComponent("\(src.deletingPathExtension().lastPathComponent)-\(n).md")
                n += 1
            }
            if (try? fm.moveItem(at: src, to: dest)) != nil {
                moves.append(FileMove(from: p, to: dest.path))
            }
        }
        return moves
    }

    /// `-Users-kevin-GitHub-Throttle` → `Throttle` (best-effort display name).
    private static func decodeName(_ encoded: String) -> String {
        encoded.split(separator: "-").map(String.init).filter { !$0.isEmpty }.last ?? encoded
    }
}
