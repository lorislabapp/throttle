import Foundation

/// Enumerates Claude Code projects from `~/.claude/projects/`.
///
/// Each subdirectory there is named with the project's filesystem path
/// encoded by replacing `/` with `-` and prepending `-`. We decode that,
/// stat the real folder, and surface a list sorted by most-recent activity.
///
/// Stale projects (no log file touched in 30+ days) are filtered by default
/// — the sidebar in the project window passes `includeArchived: false` for
/// the common case, the dogfood scope (Kevin's ~14 active projects) doesn't
/// need a "show archived" toggle at v2.0.
enum ProjectsService {
    private static let claudeProjectsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }()

    static func listProjects(includeArchived: Bool = false, now: Date = Date()) -> [ProjectInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: claudeProjectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        let archiveCutoff = now.addingTimeInterval(-30 * 24 * 3600)
        return entries
            .compactMap { entry -> ProjectInfo? in
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { return nil }
                return makeProjectInfo(encodedDir: entry, fm: fm)
            }
            .filter { includeArchived || $0.lastActive >= archiveCutoff }
            .sorted { $0.lastActive > $1.lastActive }
    }

    /// Decode the encoded dir name into the real path and stat the contents.
    private static func makeProjectInfo(encodedDir: URL, fm: FileManager) -> ProjectInfo? {
        let encodedName = encodedDir.lastPathComponent
        let decoded = decodePath(encodedName)
        let exists = decoded.flatMap { fm.fileExists(atPath: $0) ? $0 : nil } != nil
        let lastActive = mostRecentJSONLDate(in: encodedDir, fm: fm)

        let display: String
        if let path = decoded {
            display = (path as NSString).lastPathComponent
        } else {
            display = encodedName
        }

        return ProjectInfo(
            encodedName: encodedName,
            projectPath: decoded,
            displayName: display,
            lastActive: lastActive,
            pathExists: exists
        )
    }

    /// `-Users-foo-GitHub-Throttle` → `/Users/foo/GitHub/Throttle`.
    /// Returns nil for unexpected formats (no leading dash).
    static func decodePath(_ encoded: String) -> String? {
        guard encoded.hasPrefix("-") else { return nil }
        let body = String(encoded.dropFirst())
        return "/" + body.replacingOccurrences(of: "-", with: "/")
    }

    /// Walks the encoded dir (one level deep) for `.jsonl` files and returns
    /// the latest mtime. Falls back to the directory's own mtime when there
    /// are no logs (e.g. a project that was started but never produced a
    /// session). Returns `.distantPast` only if absolutely nothing is found.
    private static func mostRecentJSONLDate(in dir: URL, fm: FileManager) -> Date {
        var latest = Date.distantPast
        if let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries where entry.pathExtension == "jsonl" {
                if let mtime = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   mtime > latest {
                    latest = mtime
                }
            }
        }
        if latest == .distantPast,
           let mtime = try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            latest = mtime
        }
        return latest
    }
}
