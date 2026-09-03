import Foundation
import OSLog

enum TaskIntegrationError: Error, Equatable {
    case noWorktree(String)
    case gitFailed(String)
    /// A conflicting rebase failed to abort. The worktree may still be mid-rebase —
    /// this is deliberately distinct from `gitFailed` so a caller can tell "restored,
    /// and it conflicted" apart from "may still be half-done". Carries both outputs:
    /// the original rebase failure and the abort's own failure.
    case rebaseAbortFailed(rebaseOutput: String, abortOutput: String)
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

/// Reads a finished task's worktree, and — only on an explicit call — rebases,
/// verifies, and fast-forwards it into the base branch.
///
/// Reading never writes: `assess` computes the merge in git's object database and
/// leaves the worktree at the exact SHA the agent left it on.
enum TaskIntegrationService {

    private static let logger = Logger(subsystem: "com.lorislab.throttle",
                                       category: "TaskIntegration")

    // MARK: - Assess

    /// The task's side is read from the branch ref, and the worktree is required to
    /// still be on it.
    ///
    /// Reading the ref alone only made three of the four steps agree. `integrate`
    /// fast-forwards `task/<id>` and `diff` diffs against it, so the branch is the
    /// right thing to stamp — but `verify` runs the project's command with the
    /// *worktree* as its working directory, and a worktree on a detached HEAD would
    /// produce evidence against one tree and have it recorded as green for another;
    /// `rebase` would rewrite those detached commits and leave the branch ref where
    /// it was, so every later click refused `.behind` after the worktree had already
    /// been written to. A worktree that is not on its task branch is not a task this
    /// service can reason about, so it is refused here, once, rather than meaning
    /// something slightly different at each call site.
    static func assess(taskID: String, in repo: URL) throws -> Assessment {
        let worktree = try existingWorktree(taskID, in: repo)
        let base = try sha("HEAD", in: repo)
        let branch = try TaskWorktreeService.branchName(for: taskID)
        let task = try sha(branch, in: repo)
        guard isOnItsBranch(worktree, branch: branch) else {
            throw TaskIntegrationError.refused(.detached)
        }

        let dirty = isDirty(worktree, includingUntracked: true)
        let loose = dirty && isDirty(worktree, includingUntracked: false)

        let ahead = count(["rev-list", "--count", "\(base)..\(task)"], in: repo)
        let behind = count(["rev-list", "--count", "\(task)..\(base)"], in: repo)

        return Assessment(baseSHA: base, taskSHA: task,
                          behindBy: behind, aheadBy: ahead, isDirty: dirty,
                          hasLooseWork: loose,
                          files: numstat(base: base, task: task, in: repo),
                          mergeability: mergeability(base: base, task: task, in: repo))
    }

    static func diff(taskID: String, in repo: URL) throws -> String {
        _ = try existingWorktree(taskID, in: repo)
        let branch = try TaskWorktreeService.branchName(for: taskID)
        return git(["diff", "HEAD...\(branch)"], in: repo).output
    }

    /// `merge-tree --write-tree` writes the merged tree into the object database
    /// and nothing into the worktree or the index, so a task can be read while its
    /// agent is still looking at it. It needs git 2.38; older git gets `.unknown`
    /// rather than a guess.
    ///
    /// On conflict, real git (verified on 2.54) writes everything to stdout as
    /// `<tree OID>\n<conflicted paths>\n\n<informational messages>` — "Auto-merging
    /// …" and "CONFLICT …" lines share the stream with the path list, separated
    /// from it only by a blank line. Splitting on that blank line first keeps
    /// those messages out of the reported paths.
    private static func mergeability(base: String, task: String, in repo: URL) -> Mergeability {
        let result = git(["merge-tree", "--write-tree", "--name-only", base, task], in: repo)
        if result.ok { return .clean }
        return conflictedPaths(inMergeTreeFailure: result.output)
    }

    /// Reads a failed `merge-tree` as either a real conflict or "git did not answer".
    ///
    /// A non-zero exit is not proof of a conflict: git older than 2.38 does not know
    /// `--write-tree` and exits non-zero having printed `error: unknown option …`
    /// followed by its own usage block. Treating that as a path list rendered git's
    /// usage text to the user as "Conflicts with the base in:" and disabled the
    /// button. The conflict shape is recognised by its first line — a tree object id
    /// — and everything else is `.unknown`, which is what the spec asks for on a git
    /// that cannot answer.
    static func conflictedPaths(inMergeTreeFailure output: String) -> Mergeability {
        guard let firstSection = output.components(separatedBy: "\n\n").first else {
            return .unknown
        }
        let lines = firstSection.split(separator: "\n").map(String.init)
        guard let first = lines.first,
              isObjectID(first.trimmingCharacters(in: .whitespaces)) else { return .unknown }
        // First line is the tree OID; the rest are the conflicting paths.
        let paths = lines.dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return paths.isEmpty ? .unknown : .conflicted(Array(paths))
    }

    /// A git object id: 40 hex digits under SHA-1, 64 under SHA-256.
    private static func isObjectID(_ candidate: String) -> Bool {
        (candidate.count == 40 || candidate.count == 64)
            && candidate.allSatisfy { $0.isHexDigit }
    }

    private static func numstat(base: String, task: String, in repo: URL) -> [FileChange] {
        git(["diff", "--numstat", "\(base)...\(task)"], in: repo).output
            .split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count == 3 else { return nil }
                // "-" in place of a count means a binary file.
                return FileChange(path: String(parts[2]),
                                  added: Int(parts[0]) ?? 0,
                                  removed: Int(parts[1]) ?? 0)
            }
    }

    // MARK: - Rebase

    /// Replays the task's commits on top of the current base, inside the task's own
    /// worktree. Refuses to touch a worktree holding uncommitted work, and aborts at
    /// the first conflict so a failure leaves the agent's state exactly as it was.
    ///
    /// Tracked modifications only, like `integrate`. The strict, untracked-inclusive
    /// check bought a dead end and nothing else: a `.build/` directory or a coverage
    /// file left by the verification that just ran in this worktree blocked the *next*
    /// click's rebase, with no click that could clear it. git refuses a rebase by
    /// itself when an untracked file would actually be overwritten, and the
    /// `--abort` path below restores the worktree cleanly when it does — so the real
    /// hazard is already covered by the tool that knows which files are at stake.
    @discardableResult
    static func rebase(taskID: String, in repo: URL) throws -> Assessment {
        let worktree = try existingWorktree(taskID, in: repo)
        let before = try assess(taskID: taskID, in: repo)
        guard !before.hasLooseWork else { throw TaskIntegrationError.refused(.dirty) }
        guard before.behindBy > 0 else { return before }

        let result = git(["rebase", before.baseSHA], in: worktree)
        guard result.ok else {
            let abort = git(["rebase", "--abort"], in: worktree)
            guard abort.ok else {
                throw TaskIntegrationError.rebaseAbortFailed(rebaseOutput: result.output,
                                                              abortOutput: abort.output)
            }
            throw TaskIntegrationError.gitFailed(result.output)
        }
        return try assess(taskID: taskID, in: repo)
    }

    // MARK: - Integrate

    /// Fast-forwards the base branch onto a finished task, and writes `integrated`.
    ///
    /// Four refusals of its own, in the order that makes the message useful: a
    /// worktree still holding loose work, a task not sitting on the current base, a
    /// SOTA-gated task counter-analysis has not ruled on, and a check that is not
    /// green for these exact two SHAs. `assess`, called below, can add its own
    /// `.detached` before any of them.
    ///
    /// The gate is checked before the green check, not after: `checked` is only ever
    /// accepted on a task that has reached `.done` (see `PlanProjection`), and a
    /// gated task only reaches `.done` through a `.verified` verdict — so a gated
    /// task awaiting that verdict can never carry a green check in the first place.
    /// Reporting `.unverified` on it would be true but useless; `.ungated` says the
    /// thing that is actually blocking it.
    ///
    /// The merge itself is `--ff-only` on purpose: after a rebase the task's tip is a
    /// descendant of the base, so the merge cannot invent a conflict the shown diff
    /// did not contain. A failing fast-forward means one thing — the base moved between
    /// the diff and the click — and that is a refusal, not a merge commit.
    @discardableResult
    static func integrate(taskID: String, in repo: URL, store: PlanStore,
                          task: PlanTask, author: String) throws -> String {
        _ = try existingWorktree(taskID, in: repo)
        // A detached repo HEAD would let `merge --ff-only` succeed and advance
        // nothing a branch points at: `integrated` would be logged for a merge that
        // moved no branch. Checked before the assessment and every refusal under it,
        // because no refusal further down would be the real reason.
        guard git(["symbolic-ref", "-q", "HEAD"], in: repo).ok else {
            throw TaskIntegrationError.gitFailed(
                "The repository is on a detached HEAD — check out the base branch before integrating.")
        }
        let assessment = try assess(taskID: taskID, in: repo)
        // Tracked modifications only. The verification this integration depends on
        // just ran an arbitrary project command in that worktree, and a build or
        // coverage artefact it left behind would otherwise turn a green minutes-long
        // check into a refusal with no way forward.
        guard !assessment.hasLooseWork else {
            throw TaskIntegrationError.refused(.dirty)
        }
        guard assessment.behindBy == 0 else { throw TaskIntegrationError.refused(.behind) }

        let state = try store.state(for: taskID)
        if task.sotaGate {
            guard state.verdictBy != nil else { throw TaskIntegrationError.refused(.ungated) }
        }
        guard let check = state.lastCheck, check.passed, check.stamp == assessment.stamp else {
            throw TaskIntegrationError.refused(.unverified)
        }

        let branch = try TaskWorktreeService.branchName(for: taskID)
        let merge = git(["merge", "--ff-only", branch], in: repo)
        guard merge.ok else { throw TaskIntegrationError.gitFailed(merge.output) }

        let sha = try self.sha("HEAD", in: repo)
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: author,
                                   type: .integrated, ref: sha), to: taskID)
        return sha
    }

    /// Removes an integrated task's worktree, and returns the reason it is still
    /// standing when it is — nil means it is gone. This is the end of the
    /// accumulation this lot's scope opens by complaining about: without it, every
    /// finished task leaves a full checkout behind for ever.
    ///
    /// Never with `force`, and never throwing. `TaskWorktreeService.remove` refuses
    /// whenever the worktree still holds uncommitted changes or unmerged commits, and
    /// that refusal stays authoritative — an integration that succeeded is not a
    /// licence to delete something unexpected. Nor is a worktree left standing a
    /// reason to report a merge that already happened as a failure: the reason comes
    /// back as text for whoever asked, and the directory stays for the user to look at.
    ///
    /// *Whether* to call this is deliberately not `integrate`'s decision, which is
    /// why it is a separate function. A task's worktree is also its agent's working
    /// directory, and the cockpit opens that tab with this very path as its cwd:
    /// deleting it under a live session leaves that shell with a working directory
    /// that no longer exists, and every command typed into it afterwards fails
    /// obscurely. This service cannot see tabs, so it does not get to choose. The
    /// caller that can — `PlanModel` — does.
    static func removeWorktree(taskID: String, in repo: URL) -> String? {
        do {
            try TaskWorktreeService.remove(taskID: taskID, in: repo)
            return nil
        } catch {
            let reason: String
            if case TaskWorktreeError.hasUnintegratedWork(let detail) = error {
                reason = detail
            } else {
                reason = String(describing: error)
            }
            logger.notice("""
                worktree for \(taskID, privacy: .public) left standing after integration: \
                \(reason, privacy: .public)
                """)
            return reason
        }
    }

    // MARK: - git

    /// Not `private`: the verify half lives in `TaskIntegrationServiceVerify.swift`.
    static func existingWorktree(_ taskID: String, in repo: URL) throws -> URL {
        let path = try TaskWorktreeService.path(for: taskID, in: repo)
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw TaskIntegrationError.noWorktree(taskID)
        }
        return path
    }

    /// Whether the worktree's own HEAD *is* the task branch — not merely parked at
    /// the same commit. `symbolic-ref` answers what a SHA comparison cannot: a
    /// detached HEAD sitting exactly on the tip would still let `rebase` rewrite the
    /// commits under it and leave the branch ref behind.
    private static func isOnItsBranch(_ worktree: URL, branch: String) -> Bool {
        let head = git(["symbolic-ref", "-q", "HEAD"], in: worktree)
        return head.ok
            && head.output.trimmingCharacters(in: .whitespacesAndNewlines) == "refs/heads/\(branch)"
    }

    /// `includingUntracked: false` asks git the narrower question — are any *tracked*
    /// files modified — which is the only one a fast-forward performed elsewhere cares
    /// about.
    private static func isDirty(_ worktree: URL, includingUntracked: Bool) -> Bool {
        let args = includingUntracked
            ? ["status", "--porcelain"]
            : ["status", "--porcelain", "--untracked-files=no"]
        return !git(args, in: worktree).output
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func sha(_ rev: String, in directory: URL) throws -> String {
        let result = git(["rev-parse", rev], in: directory)
        guard result.ok else { throw TaskIntegrationError.gitFailed(result.output) }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func count(_ args: [String], in directory: URL) -> Int {
        Int(git(args, in: directory).output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    @discardableResult
    static func git(_ args: [String], in directory: URL) -> (ok: Bool, output: String) {
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
