import Foundation

/// Detects content duplicated across project `CLAUDE.md` files — the same
/// guidance copy-pasted into many repos, paid for on every session of each.
/// The fix is to hoist it to a shared on-demand skill. Detection is read-only;
/// the hoist action edits files but always backs them up first (reversible).
struct DuplicatedBlock: Sendable, Identifiable {
    let id: String            // the normalized text (stable within a scan; used to match per file)
    let text: String          // a representative copy, as written
    let projects: [String]    // project names that contain it
    let paths: [String]       // the CLAUDE.md file paths that contain it
    let tokensPerLoad: Int     // ≈ cost of one copy at session start
    /// Tokens wasted across the portfolio: every project loads its copy each session.
    var wasteTokens: Int { tokensPerLoad * paths.count }
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
        // normalized block -> (representative text, set of CLAUDE.md paths)
        var map: [String: (text: String, paths: Set<String>)] = [:]
        var projectsSeen = Set<String>()

        for entry in entries.prefix(80) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let realPath = decodeProjectPath(entry.lastPathComponent) else { continue }
            let claudeMd = URL(fileURLWithPath: realPath).appendingPathComponent("CLAUDE.md")
            guard let content = try? String(contentsOf: claudeMd, encoding: .utf8) else { continue }
            projectsSeen.insert((realPath as NSString).lastPathComponent)
            for block in blocks(in: content) {
                let key = normalized(block)
                guard key.count >= 40 else { continue }
                var e = map[key] ?? (block, [])
                e.paths.insert(claudeMd.path)
                e.text = block
                map[key] = e
            }
        }

        let dups = map
            .filter { $0.value.paths.count >= 2 }
            .map { kv -> DuplicatedBlock in
                let projects = kv.value.paths.map { (($0 as NSString).deletingLastPathComponent as NSString).lastPathComponent }.sorted()
                return DuplicatedBlock(id: kv.key, text: kv.value.text, projects: projects,
                                       paths: kv.value.paths.sorted(), tokensPerLoad: max(1, TokenEstimate.fromBytes(kv.value.text.utf8.count, kind: .dense)))
            }
            .sorted { $0.wasteTokens > $1.wasteTokens }

        return DedupReport(blocks: Array(dups.prefix(25)), projectCount: projectsSeen.count)
    }

    /// Hoist a duplicated block into a shared on-demand skill, then remove it
    /// from each project's CLAUDE.md. Every edited file is backed up first to
    /// ~/.claude/throttle-backups (reversible). Returns true on success.
    @discardableResult
    static func hoist(_ block: DuplicatedBlock) -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let slug = makeSlug(block.text)

        // 1) Create the shared skill (additive, safe). Description is best-effort —
        //    the user should refine it so the skill triggers correctly.
        let skillDir = home.appendingPathComponent(".claude/skills/shared-\(slug)", isDirectory: true)
        guard (try? fm.createDirectory(at: skillDir, withIntermediateDirectories: true)) != nil else { return false }
        let firstLine = block.text.split(separator: "\n").first.map(String.init) ?? "shared guidance"
        let desc = "Shared guidance hoisted from \(block.paths.count) project CLAUDE.md files — REFINE this description so it triggers when relevant. Topic: \(firstLine.prefix(120))"
        let skillMd = "---\nname: shared-\(slug)\ndescription: \(desc)\n---\n\n\(block.text)\n"
        guard (try? skillMd.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)) != nil else { return false }

        // 2) Back up + remove the block from each CLAUDE.md (match by normalized paragraph).
        let backups = home.appendingPathComponent(".claude/throttle-backups", isDirectory: true)
        try? fm.createDirectory(at: backups, withIntermediateDirectories: true)
        for path in block.paths {
            let url = URL(fileURLWithPath: path)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let project = (((path as NSString).deletingLastPathComponent) as NSString).lastPathComponent
            // backup
            try? content.write(to: backups.appendingPathComponent("\(project)-CLAUDE.md.bak"), atomically: true, encoding: .utf8)
            // remove the paragraph whose normalized form matches the block
            let paras = content.components(separatedBy: "\n\n")
            let kept = paras.filter { normalized($0.trimmingCharacters(in: .whitespacesAndNewlines)) != block.id }
            if kept.count < paras.count {
                try? kept.joined(separator: "\n\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }
        return true
    }

    private static func makeSlug(_ text: String) -> String {
        let first = text.split(separator: "\n").first.map(String.init) ?? "block"
        let cleaned = first.lowercased()
            .replacingOccurrences(of: "#", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            .prefix(4).joined(separator: "-")
        return cleaned.isEmpty ? "guidance" : String(cleaned.prefix(40))
    }

    private static func blocks(in content: String) -> [String] {
        content.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { ($0.count >= 40 && $0.contains("\n")) || $0.count >= 60 }
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func decodeProjectPath(_ encoded: String) -> String? {
        let path = encoded.replacingOccurrences(of: "-", with: "/")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}
