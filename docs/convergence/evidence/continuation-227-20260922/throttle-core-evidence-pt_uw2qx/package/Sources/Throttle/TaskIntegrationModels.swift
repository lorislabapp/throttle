import Foundation

enum TaskIntegrationError: Error, Equatable {
    case noWorktree(String)
    case gitFailed(String)
    /// A conflicting rebase failed to abort. The worktree may still be mid-rebase —
    /// this is deliberately distinct from `gitFailed` so a caller can tell "restored,
    /// and it conflicted" apart from "may still be half-done". Carries both outputs:
    /// the original rebase failure and the abort's own failure.
    case rebaseAbortFailed(rebaseOutput: String, abortOutput: String)
    case scopeViolation([String])
    /// A guard that held. Rendered to the user as-is, so each case says which one.
    case refused(Refusal)

    enum Refusal: String, Sendable {
        /// `detached` is raised by `assess`, so it reaches every step below it.
        /// The other four are `integrate`'s own.
        case dirty, behind, unverified, ungated, detached
    }
}

struct FileChange: Sendable, Equatable {
    let path: String
    let added: Int
    let removed: Int
}

/// What a merge would do, computed without performing one.
enum Mergeability: Sendable, Equatable {
    case clean
    case conflicted([String])
    /// git is too old to answer without writing something. Saying so is better
    /// than guessing on the user's behalf.
    case unknown
}

struct Assessment: Sendable, Equatable {
    let baseSHA: String
    let taskSHA: String
    /// Commits the base has that the task branch does not — what a rebase would replay onto.
    let behindBy: Int
    let aheadBy: Int
    /// Anything at all in the worktree that git would report, untracked files
    /// included. Shown, never used to refuse: a `.build/` directory is not work.
    let isDirty: Bool
    /// Tracked files with uncommitted modifications — the narrower question, and the
    /// only one any step here refuses on. A verification runs an arbitrary project
    /// command in that worktree, and the artefacts it leaves behind must not dead-end
    /// the next click.
    let hasLooseWork: Bool
    let files: [FileChange]
    let mergeability: Mergeability

    /// The two SHAs a verification was true for. A check is green only while both
    /// still hold, so integrating one task stales every other check by itself.
    var stamp: String { "\(taskSHA)+\(baseSHA)" }
}
