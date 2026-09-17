import Foundation

/// Which project a session works in. Automatic by default — the repository
/// that contains its folder, with a git worktree folded back into the
/// repository it was created from — and overridable per folder when the
/// guess is wrong (a monorepo package, a scratch folder beside a project).
enum SessionProjectResolver {

    static let overridesKey = "cockpitSessionProjectOverrides"

    /// The project root for a working directory, or nil when the folder is not
    /// inside any repository and nobody attached it to one.
    static func projectRoot(forWorkingDirectory cwd: String,
                            overrides: [String: String] = storedOverrides(),
                            fileManager: FileManager = .default) -> String? {
        let start = URL(fileURLWithPath: cwd).standardizedFileURL
        if let manual = overrides[start.path] { return manual }
        var directory = start
        while directory.path != "/" {
            let git = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return directory.path }
                return mainRepository(fromGitFile: git) ?? directory.path
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    /// A worktree's `.git` is a file: `gitdir: /repo/.git/worktrees/<name>`.
    /// The project is the repository that owns that `.git` directory.
    static func mainRepository(fromGitFile url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard let range = gitdir.range(of: "/.git/worktrees/") else { return nil }
        return String(gitdir[..<range.lowerBound])
    }

    // MARK: Manual attachment

    static func storedOverrides(_ defaults: UserDefaults = .standard) -> [String: String] {
        defaults.dictionary(forKey: overridesKey) as? [String: String] ?? [:]
    }

    /// Attaches every session working in `cwd` to `projectRoot`; nil detaches.
    static func setOverride(cwd: String, projectRoot: String?, defaults: UserDefaults = .standard) {
        var overrides = storedOverrides(defaults)
        let key = URL(fileURLWithPath: cwd).standardizedFileURL.path
        overrides[key] = projectRoot.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        defaults.set(overrides, forKey: overridesKey)
    }
}
