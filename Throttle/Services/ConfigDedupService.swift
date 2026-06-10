import Foundation

/// Detects content duplicated across project `CLAUDE.md` files — the same
/// guidance copy-pasted into many repos, paid for on every session of each.
/// The fix is to hoist it to a shared on-demand skill. v1 detects + quantifies;
/// it never edits the user's files (apply-with-rollback is a later phase).
struct DuplicatedBlock: Sendable, Identifiable {
    let id: String            // the normalized text (stable within a scan)
    let text: String          // a representative copy, as written
    let projects: [String]    // project names that contain it
    let tokensPerLoad: Int    // ≈ cost of one copy at session start
    /// Tokens wasted across the portfolio: every project loads its copy each session.
    var wasteTokens: Int { tokensPerLoad * projects.count }
}

struct DedupReport: Sendable {
    let blocks: [DuplicatedBlock]
    let projectCount: Int
    var totalWasteTokens: Int { blocks.reduce(0) { $0 + $1.wasteTokens } }
    static let empty = DedupReport(blocks: [], projectCount: 0)
}

enum ConfigDedupService {
    /// Scan project CLAUDE.md files for blocks that appear in ≥2 projects.
    static func scan() -> DedupReport {
        let fm = FileManager.default
        let projectsDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return .empty
        }
        // normalized block -> (representative text, set of project names)
        var map: [String: (text: String, projects: Set<String>)] = [:]
        var projectsSeen = Set<String>()

        for entry in entries.prefix(80) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let realPath = decodeProjectPath(entry.lastPathComponent) else { continue }
            let claudeMd = URL(fileURLWithPath: realPath).appendingPathComponent("CLAUDE.md")
            guard let content = try? String(contentsOf: claudeMd, encoding: .utf8) else { continue }
            let name = (realPath as NSString).lastPathComponent
            projectsSeen.insert(name)
            for block in blocks(in: content) {
                let key = normalized(block)
                guard key.count >= 40 else { continue }
                var entry = map[key] ?? (block, [])
                entry.projects.insert(name)
                entry.text = block
                map[key] = entry
            }
        }

        let dups = map
            .filter { $0.value.projects.count >= 2 }
            .map { kv in
                DuplicatedBlock(id: kv.key, text: kv.value.text,
                                projects: kv.value.projects.sorted(),
                                tokensPerLoad: max(1, kv.value.text.count / 4))
            }
            .sorted { $0.wasteTokens > $1.wasteTokens }

        return DedupReport(blocks: Array(dups.prefix(25)), projectCount: projectsSeen.count)
    }

    /// Split a CLAUDE.md into candidate blocks (blank-line separated), keeping
    /// only substantial ones (multi-line ≥40 chars, or a long single line).
    private static func blocks(in content: String) -> [String] {
        content.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { ($0.count >= 40 && $0.contains("\n")) || $0.count >= 60 }
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// `-Users-kevin-GitHub-Clasp` → `/Users/kevin/GitHub/Clasp`.
    /// Lossy for paths whose components contain a dash; those projects are skipped.
    private static func decodeProjectPath(_ encoded: String) -> String? {
        let path = encoded.replacingOccurrences(of: "-", with: "/")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}
