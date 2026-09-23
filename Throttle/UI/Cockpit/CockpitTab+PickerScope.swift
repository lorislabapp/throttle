import Foundation

@MainActor
extension CockpitTab {
    /// Whether this tab already holds `nativeID` for `tab`: it resumes that exact
    /// conversation, or its open native picker could still choose it. A picker
    /// only lists conversations of its own repository (every worktree of it), so a
    /// picker left open in one project no longer blocks resuming in all the others.
    func holdsOrMayChoose(_ nativeID: String, for tab: CockpitTab) -> Bool {
        guard self !== tab, runtime == tab.runtime, isSpawned else { return false }
        if sessionId?.caseInsensitiveCompare(nativeID) == .orderedSame { return true }
        return isChoosingNativeSession && Self.pickerScope(cwd: cwd) == Self.pickerScope(cwd: tab.cwd)
    }

    /// The repository's shared git directory, so all worktrees of one repository
    /// share a scope; the directory itself outside any repository. Anything
    /// unreadable falls back to the directory, which only ever widens the match
    /// for tabs in that same directory.
    nonisolated static func pickerScope(cwd: String) -> String {
        let files = FileManager.default
        let start = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL
        var dir = start
        while true {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if files.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                if isDir.boolValue { return dotGit.resolvingSymlinksInPath().standardizedFileURL.path }
                return commonGitDir(worktreeFile: dotGit, base: dir)?.path ?? start.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return start.path }
            dir = parent
        }
    }

    /// `.git` as a file (a linked worktree): "gitdir: <path>", whose `commondir`
    /// names the main repository's git directory.
    nonisolated private static func commonGitDir(worktreeFile: URL, base: URL) -> URL? {
        guard let text = try? String(contentsOf: worktreeFile, encoding: .utf8),
              let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
        let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let gitDir = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : base.appendingPathComponent(raw)
        guard let common = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8)
        else { return gitDir.resolvingSymlinksInPath().standardizedFileURL }
        let path = common.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : gitDir.appendingPathComponent(path)
        return url.resolvingSymlinksInPath().standardizedFileURL
    }
}
