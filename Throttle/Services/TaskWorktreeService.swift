import Foundation

enum TaskWorktreeError: Error, Equatable {
    case unsafeTaskID(String)
    case notARepository(String)
    case gitFailed(String)
    /// Refused because the worktree still holds work nobody has integrated.
    case hasUnintegratedWork(String)
}

/// Gives each task its own git worktree, so parallel agents cannot overwrite each
/// other and their conflicts surface at merge time where git can see them.
///
/// This service creates and removes directories, so its rules are conservative by
/// construction: it never removes a worktree that still contains work, and it
/// never merges. Integration is a human decision.
enum TaskWorktreeService {

    private static let root = ".claude/worktrees"

    /// Task ids become directory names and branch names.
    private static func validated(_ taskID: String) throws -> String {
        let isSafe = !taskID.isEmpty && taskID.count <= 128
            && !taskID.contains("/") && !taskID.contains("\\")
            && !taskID.contains("..") && !taskID.hasPrefix(".")
            && !taskID.contains(" ")
        guard isSafe else { throw TaskWorktreeError.unsafeTaskID(taskID) }
        return taskID
    }

    static func path(for taskID: String, in repo: URL) throws -> URL {
        repo.appendingPathComponent("\(root)/\(try validated(taskID))", isDirectory: true)
    }

    static func branchName(for taskID: String) throws -> String {
        "task/\(try validated(taskID))"
    }

    // MARK: - Create

    /// Idempotent: an existing worktree for this task is returned as-is rather
    /// than recreated, so relaunching a task never discards what it already holds.
    @discardableResult
    static func create(taskID: String, in repo: URL, base: String = "HEAD") throws -> URL {
        let destination = try path(for: taskID, in: repo)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        guard git(["rev-parse", "--git-dir"], in: repo).ok else {
            throw TaskWorktreeError.notARepository(repo.path)
        }
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(root, isDirectory: true),
            withIntermediateDirectories: true)

        let branch = try branchName(for: taskID)
        let existingBranch = git(["rev-parse", "--verify", branch], in: repo).ok
        let args = existingBranch
            ? ["worktree", "add", destination.path, branch]
            : ["worktree", "add", destination.path, "-b", branch, base]
        let result = git(args, in: repo)
        guard result.ok else { throw TaskWorktreeError.gitFailed(result.output) }
        return destination
    }

    // MARK: - Inspect

    struct Status: Sendable, Equatable {
        let exists: Bool
        /// Uncommitted changes in the worktree.
        let isDirty: Bool
        /// Commits on the task branch that the base branch does not have.
        let unmergedCommits: Int

        var holdsWork: Bool { isDirty || unmergedCommits > 0 }
    }

    static func status(taskID: String, in repo: URL, base: String = "HEAD") throws -> Status {
        let destination = try path(for: taskID, in: repo)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return Status(exists: false, isDirty: false, unmergedCommits: 0)
        }
        let dirty = !git(["status", "--porcelain"], in: destination).output
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let ahead = git(["rev-list", "--count", "\(base)..HEAD"], in: destination)
        let unmerged = Int(ahead.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return Status(exists: true, isDirty: dirty, unmergedCommits: unmerged)
    }

    // MARK: - Remove

    /// Removes a task's worktree, and refuses whenever it still holds work.
    ///
    /// `force` exists for the case where the user has looked at the diff and said
    /// to drop it. It is never set by Throttle on its own — no automatic path in
    /// this app deletes work an agent produced.
    static func remove(taskID: String, in repo: URL, base: String = "HEAD",
                       force: Bool = false) throws {
        let state = try status(taskID: taskID, in: repo, base: base)
        guard state.exists else { return }
        if state.holdsWork && !force {
            let what = state.isDirty ? "uncommitted changes" : "\(state.unmergedCommits) unmerged commit(s)"
            throw TaskWorktreeError.hasUnintegratedWork(
                "\(taskID) still has \(what) — look at the diff before it goes away")
        }
        let destination = try path(for: taskID, in: repo)
        var args = ["worktree", "remove", destination.path]
        if force { args.append("--force") }
        let result = git(args, in: repo)
        guard result.ok else { throw TaskWorktreeError.gitFailed(result.output) }
    }

    // MARK: - git

    private static func git(_ args: [String], in directory: URL) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus == 0, String(bytes: data, encoding: .utf8) ?? "")
        } catch {
            return (false, String(describing: error))
        }
    }
}
