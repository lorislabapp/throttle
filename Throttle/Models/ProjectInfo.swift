import Foundation

/// One Claude Code project as Throttle sees it. Combines:
///   - the encoded directory under `~/.claude/projects/` (session logs)
///   - the decoded real filesystem path (project root, where the user works)
///   - per-project config files (CLAUDE.md, .claude/, etc.) when present
///   - last-active timestamp for sorting / archive filtering
struct ProjectInfo: Identifiable, Sendable, Hashable {
    /// Stable id = encoded directory name.
    var id: String { encodedName }

    /// e.g. "-Users-kevinnadjarian-GitHub-Throttle"
    let encodedName: String

    /// Decoded path on disk, e.g. "/Users/kevinnadjarian/GitHub/Throttle".
    /// Nil if the decode fails (shouldn't happen for valid Claude folders).
    let projectPath: String?

    /// Display name = last path component of `projectPath`.
    let displayName: String

    /// Most recent jsonl log mtime, or .distantPast if no logs.
    let lastActive: Date

    /// True when the decoded path actually exists on disk.
    /// Useful to grey out projects whose folder was deleted/moved.
    let pathExists: Bool

    var url: URL? {
        guard let projectPath else { return nil }
        return URL(fileURLWithPath: projectPath)
    }

    /// `<projectPath>/CLAUDE.md` if the file exists.
    var claudeMdURL: URL? {
        guard let url else { return nil }
        let candidate = url.appendingPathComponent("CLAUDE.md")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// `<projectPath>/.claude/settings.json` if it exists.
    var settingsJSONURL: URL? {
        guard let url else { return nil }
        let candidate = url.appendingPathComponent(".claude/settings.json")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// `<projectPath>/.claude/settings.local.json` (gitignored variant).
    var settingsLocalJSONURL: URL? {
        guard let url else { return nil }
        let candidate = url.appendingPathComponent(".claude/settings.local.json")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Path to the encoded sessions directory under ~/.claude/projects/.
    var sessionsURL: URL? {
        let claudeProjects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        return claudeProjects.appendingPathComponent(encodedName)
    }
}
