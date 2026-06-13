import Foundation

/// Skill-usage analytics — the Capabilities pillar of the AIOS audit. Cross-refs
/// the installed global skills (`~/.claude/skills/`) against how often each
/// actually fires in the session transcripts (`{"name":"Skill","input":{"skill":"X"}}`)
/// to surface dead weight: skills installed but never invoked still sit in the
/// always-loaded skill index. Detect + recommend only; never deletes a skill.
struct SkillUsage: Sendable, Identifiable {
    let id: String          // skill name
    let name: String
    let invocations: Int
    let tokens: Int          // SKILL.md size estimate (index + on-demand load)
    var dead: Bool { invocations == 0 }
}

struct SkillReport: Sendable {
    let skills: [SkillUsage]
    var deadCount: Int { skills.filter { $0.dead }.count }
    var deadTokens: Int { skills.filter { $0.dead }.reduce(0) { $0 + $1.tokens } }
    static let empty = SkillReport(skills: [])
}

enum SkillUsageService {
    static func scan() -> SkillReport {
        let installed = installedSkills()
        guard !installed.isEmpty else { return .empty }
        let counts = invocationCounts()
        let skills = installed.map { (name, tokens) in
            SkillUsage(id: name, name: name, invocations: counts[name] ?? 0, tokens: tokens)
        }.sorted { ($0.invocations, $1.tokens) < ($1.invocations, $0.tokens) }  // dead/light first
        return SkillReport(skills: skills)
    }

    /// Archive a skill by MOVING it to ~/.claude/skills-archive (reversible —
    /// never deletes). Claude Code won't load skills from outside ~/.claude/skills.
    static func archive(skillName: String) throws {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let skills = home.appendingPathComponent(".claude/skills", isDirectory: true)
        let archive = home.appendingPathComponent(".claude/skills-archive", isDirectory: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)

        let asDir = skills.appendingPathComponent(skillName, isDirectory: true)
        let asMd = skills.appendingPathComponent(skillName + ".md")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: asDir.path, isDirectory: &isDir), isDir.boolValue {
            try moveAvoidingClash(asDir, into: archive, name: skillName, fm: fm)
        } else if fm.fileExists(atPath: asMd.path) {
            try moveAvoidingClash(asMd, into: archive, name: skillName + ".md", fm: fm)
        }
    }

    private static func moveAvoidingClash(_ src: URL, into dir: URL, name: String, fm: FileManager) throws {
        var dest = dir.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(name)-\(n)"); n += 1
        }
        try fm.moveItem(at: src, to: dest)
    }

    /// Installed global skills: directories with a SKILL.md, plus standalone .md.
    private static func installedSkills() -> [(name: String, tokens: Int)] {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills", isDirectory: true)
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else {
            return []
        }
        var out: [(String, Int)] = []
        for item in items {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir {
                let skillMd = item.appendingPathComponent("SKILL.md")
                let size = (try? skillMd.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size > 0 else { continue }
                out.append((item.lastPathComponent, max(1, size * 250 / 1024)))
            } else if item.pathExtension == "md" {
                let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                out.append(((item.lastPathComponent as NSString).deletingPathExtension, max(1, size * 250 / 1024)))
            }
        }
        return out
    }

    /// Count `{"name":"Skill","input":{"skill":"X"}}` across all transcripts via grep.
    private static func invocationCounts() -> [String: Int] {
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        p.arguments = ["-rhoE", "\"name\":\"Skill\",\"input\":\\{\"skill\":\"[A-Za-z0-9_.-]+\"", projects]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var counts: [String: Int] = [:]
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
            // …"skill":"X"  → take the trailing quoted token
            guard let r = line.range(of: "\"skill\":\"") else { continue }
            let tail = line[r.upperBound...]
            let name = tail.prefix { $0 != "\"" }
            if !name.isEmpty { counts[String(name), default: 0] += 1 }
        }
        return counts
    }
}
