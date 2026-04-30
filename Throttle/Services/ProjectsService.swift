import Foundation
import OSLog

private let projectsLog = Logger(subsystem: "com.lorislab.throttle", category: "ProjectsService")

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
        projectsLog.info("listProjects scanning \(claudeProjectsDir.path, privacy: .public) includeArchived=\(includeArchived)")
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: claudeProjectsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        } catch {
            projectsLog.error("listProjects: contentsOfDirectory failed at \(claudeProjectsDir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // Diagnostic: try a raw POSIX readdir to see if it's a Foundation
            // wrapper issue or a real permission problem.
            let cPath = claudeProjectsDir.path.cString(using: .utf8) ?? []
            if let dir = opendir(cPath) {
                var posixCount = 0
                while readdir(dir) != nil { posixCount += 1 }
                closedir(dir)
                projectsLog.error("listProjects: POSIX readdir saw \(posixCount) entries — Foundation FM is blocked")
            } else {
                let err = String(cString: strerror(errno))
                projectsLog.error("listProjects: POSIX opendir errno=\(errno) — \(err, privacy: .public)")
            }
            return []
        }
        projectsLog.info("listProjects: \(entries.count) raw entries")
        let archiveCutoff = now.addingTimeInterval(-30 * 24 * 3600)
        let infos: [ProjectInfo] = entries.compactMap { entry in
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { return nil }
            return makeProjectInfo(encodedDir: entry, fm: fm)
        }
        let filtered = infos.filter { includeArchived || $0.lastActive >= archiveCutoff }
        projectsLog.info("listProjects: built=\(infos.count) filtered=\(filtered.count) cutoff=\(archiveCutoff.ISO8601Format())")
        return filtered.sorted { $0.lastActive > $1.lastActive }
    }

    /// Build a ProjectInfo from an encoded dir. We use the FAST naive
    /// decode here (per-project) so listing 44 projects stays sub-100ms;
    /// the smart decode (try-on-disk for hyphenated dirs) runs lazily
    /// from `ProjectInfo.smartProjectPath` only when the user actually
    /// clicks a project. Same for `pathExists` — we don't probe disk
    /// during list build.
    private static func makeProjectInfo(encodedDir: URL, fm: FileManager) -> ProjectInfo? {
        let encodedName = encodedDir.lastPathComponent
        let naive = naiveDecodePath(encodedName)
        let display = naive.flatMap { ($0 as NSString).lastPathComponent }
            ?? encodedName
        let lastActive = mostRecentJSONLDate(in: encodedDir, fm: fm)
        return ProjectInfo(
            encodedName: encodedName,
            projectPath: naive,
            displayName: display,
            lastActive: lastActive,
            pathExists: false  // populated on-click via smartProjectPath
        )
    }

    /// Cheap, lossy decode used during list build. Mirrors the format
    /// Claude Code stores: leading "-", "/" replaced by "-". This will
    /// be wrong for projects whose name contains a "-" (Lumen-for-Frigate
    /// becomes /Lumen/for/Frigate) — `ProjectInfo.smartProjectPath` does
    /// the heavier work only when the user actually selects the project.
    static func naiveDecodePath(_ encoded: String) -> String? {
        guard encoded.hasPrefix("-") else { return nil }
        let body = String(encoded.dropFirst())
        return "/" + body.replacingOccurrences(of: "-", with: "/")
    }

    /// `-Users-foo-GitHub-Throttle` → `/Users/foo/GitHub/Throttle`.
    ///
    /// Claude Code's encoding is lossy — `Lumen-for-Frigate` and
    /// `Lumen/for/Frigate` both encode to `-Users-…-Lumen-for-Frigate`,
    /// so a naive replace produces the wrong path for hyphenated dirs.
    /// We mitigate by trying the naive decode first, then a series of
    /// candidates merging adjacent path segments. The first candidate
    /// that exists on disk wins; if none exist, we fall back to the
    /// naive decode (still useful as a label).
    static func decodePath(_ encoded: String) -> String? {
        guard encoded.hasPrefix("-") else { return nil }
        let body = String(encoded.dropFirst())
        let segments = body.components(separatedBy: "-")
        let fm = FileManager.default

        // Try every binary partitioning of segments where consecutive
        // segments either become a "-" inside a single path component or
        // a "/" between path components. With N segments, that's 2^(N-1)
        // candidates — bounded at 12 segments (4096 candidates) to keep
        // the work cheap. Most real paths have ≤6 segments.
        let maxSegments = min(segments.count, 12)
        let limited = Array(segments.prefix(maxSegments)) + (segments.count > maxSegments ? [] : [])
        let suffix = segments.count > maxSegments
            ? "/" + segments.dropFirst(maxSegments).joined(separator: "/")
            : ""

        // Naive decode first (fastest path, correct for the common case).
        let naive = "/" + body.replacingOccurrences(of: "-", with: "/")
        if fm.fileExists(atPath: naive) { return naive }

        let candidatesCount = 1 << max(0, limited.count - 1)
        for mask in 0..<candidatesCount {
            var pieces: [String] = []
            var current = limited.first ?? ""
            for i in 1..<limited.count {
                let separatorBit = (mask >> (i - 1)) & 1
                if separatorBit == 0 {
                    // "/" between segments
                    pieces.append(current)
                    current = limited[i]
                } else {
                    // "-" inside a segment
                    current += "-" + limited[i]
                }
            }
            pieces.append(current)
            let candidate = "/" + pieces.joined(separator: "/") + suffix
            if fm.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return naive
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
