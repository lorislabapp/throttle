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

    /// Archive stale memory files by MOVING them to ~/.claude/memory-archive
    /// (reversible — never deletes), preserving the project sub-path. Returns
    /// the count moved.
    @discardableResult
    static func archive(paths: [String]) -> Int {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let projects = home.appendingPathComponent(".claude/projects").path
        let base = home.appendingPathComponent(".claude/memory-archive", isDirectory: true)
        var moved = 0
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
            if (try? fm.moveItem(at: src, to: dest)) != nil { moved += 1 }
        }
        return moved
    }

    /// `-Users-kevin-GitHub-Throttle` → `Throttle` (best-effort display name).
    private static func decodeName(_ encoded: String) -> String {
        encoded.split(separator: "-").map(String.init).filter { !$0.isEmpty }.last ?? encoded
    }
}
