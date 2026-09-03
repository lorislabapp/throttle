import Foundation

/// One question about open cockpit tabs, asked from outside the cockpit.
///
/// A task's git worktree is also its agent's working directory: `TaskLauncher`
/// hands that path to the cockpit as a session's cwd. Integrating the task makes
/// the worktree removable, and removing it under a live tab leaves that shell with
/// a working directory that no longer exists — every command typed into it
/// afterwards fails obscurely. `PlanModel` asks this before it removes anything.
///
/// Its own file rather than a member of `MultiCockpitRoot`: the rule is a fact
/// about paths, and putting it here means it can be tested without a view.
enum SessionWorkingDirectory {

    /// Whether any session's working directory *is* `directory` or sits inside it.
    ///
    /// Compared as path components, not as a prefix of characters: `/tmp/wt-2`
    /// starts with `/tmp/wt` and is a different directory.
    static func isSessionWorking(inside directory: URL, of sessions: [CockpitTab]) -> Bool {
        let target = directory.standardizedFileURL.path
        return sessions.contains { session in
            guard !session.cwd.isEmpty else { return false }
            let cwd = URL(fileURLWithPath: session.cwd, isDirectory: true).standardizedFileURL.path
            return cwd == target || cwd.hasPrefix(target + "/")
        }
    }
}
