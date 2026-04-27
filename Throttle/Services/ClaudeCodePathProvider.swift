import Foundation

enum ClaudeCodePathProvider {
    /// Resolves the projects directory or returns nil if Claude Code is not installed.
    static func projectsDirectory() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".claude/projects", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) else { return nil }
        return isDir.boolValue ? dir : nil
    }

    /// Recursively finds all `.jsonl` files under projectsDirectory.
    static func discoverSessionFiles() -> [URL] {
        guard let dir = projectsDirectory() else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension == "jsonl" {
                results.append(url)
            }
        }
        return results
    }
}
