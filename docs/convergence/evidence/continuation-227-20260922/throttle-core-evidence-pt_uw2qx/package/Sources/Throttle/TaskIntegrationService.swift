import Foundation
import OSLog

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
        let result = git(["diff", "HEAD...\(branch)"], in: repo)
        guard result.ok else { throw TaskIntegrationError.gitFailed(result.output) }
        return result.output
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
        let store = PlanStore(projectRoot: repo)
        try requireValidJournal(taskID: taskID, store: store)
        if store.planExists(), let pending = try store.state(for: taskID).pendingVerification {
            throw TaskVerificationError.unresolvedExecution(pending.id)
        }
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
        try requireValidJournal(taskID: taskID, store: store)
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
        let persistedTask = try validatedTaskContract(
            taskID: taskID,
            callerTask: task,
            assessment: assessment,
            store: store
        )
        // Tracked modifications only. The verification this integration depends on
        // just ran an arbitrary project command in that worktree, and a build or
        // coverage artefact it left behind would otherwise turn a green minutes-long
        // check into a refusal with no way forward.
        guard !assessment.hasLooseWork else {
            throw TaskIntegrationError.refused(.dirty)
        }
        guard assessment.behindBy == 0 else { throw TaskIntegrationError.refused(.behind) }

        let state = try store.state(for: taskID)
        guard state.chainValid else { throw PlanStoreError.invalidLog(taskID) }
        if task.sotaGate {
            try validateReviewGate(task: persistedTask, state: state)
        }
        guard let check = state.lastCheck, check.passed, check.stamp == assessment.stamp else {
            throw TaskIntegrationError.refused(.unverified)
        }
        // Read the persisted requirements, not the caller's potentially stale task.
        // A removed contract also invalidates evidence collected under that contract.
        let contract = persistedTask.effectiveVerificationContract
        guard contract.map({ $0.accepts(check.receipt, stamp: assessment.stamp) })
            ?? (check.receipt?.contractDigest == nil) else {
            throw TaskIntegrationError.refused(.unverified)
        }
        guard persistedTask.workContract.map({
            check.receipt?.workContractDigest == $0.digest
        }) ?? (check.receipt?.workContractDigest == nil) else {
            throw TaskIntegrationError.refused(.unverified)
        }

        let sha = try mergeVerifiedRevision(assessment, in: repo)
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: author,
                                   type: .integrated, ref: sha), to: taskID)
        return sha
    }

    /// Refuse unreadable history before Git can change objects, refs or a worktree.
    /// This preflight does not serialize concurrent journal edits with Git effects.
    private static func requireValidJournal(taskID: String, store: PlanStore) throws {
        guard try store.events(for: taskID).chainValid else { throw PlanStoreError.invalidLog(taskID) }
    }

    /// Use the immutable object that was checked, never a task ref that another
    /// agent may have advanced. This narrows the merge target; it does not make
    /// checkout, merge and journal append a single recoverable transaction.
    static func mergeVerifiedRevision(_ assessment: Assessment, in repo: URL) throws -> String {
        guard isObjectID(assessment.baseSHA), isObjectID(assessment.taskSHA) else {
            throw TaskIntegrationError.refused(.unverified)
        }
        let branch = git(["symbolic-ref", "-q", "HEAD"], in: repo)
        guard branch.ok else { throw TaskIntegrationError.refused(.detached) }
        guard try sha("HEAD", in: repo) == assessment.baseSHA else {
            throw TaskIntegrationError.refused(.unverified)
        }
        // A repository hook is executable project code, outside this operation's
        // authorization to fast-forward an already verified revision.
        let merge = git(["-c", "core.hooksPath=/dev/null", "merge", "--ff-only", assessment.taskSHA], in: repo)
        guard merge.ok else { throw TaskIntegrationError.gitFailed(merge.output) }
        let resultingSHA = try sha("HEAD", in: repo)
        let resultingBranch = git(["symbolic-ref", "-q", "HEAD"], in: repo)
        guard resultingSHA == assessment.taskSHA,
              resultingBranch.ok, resultingBranch.output == branch.output else {
            throw TaskIntegrationError.gitFailed(
                "Repository state changed during integration; reconcile the actual branch before retrying.")
        }
        return resultingSHA
    }

    private static func validatedTaskContract(
        taskID: String,
        callerTask: PlanTask,
        assessment: Assessment,
        store: PlanStore
    ) throws -> PlanTask {
        guard let persisted = try store.loadPlan().task(taskID),
              persisted.contractIsValid,
              persisted.workContract?.digest == callerTask.workContract?.digest else {
            throw TaskIntegrationError.refused(.unverified)
        }
        if let contract = persisted.workContract {
            let disallowed = contract.disallowedChanges(assessment.files.map(\.path))
            guard disallowed.isEmpty else {
                throw TaskIntegrationError.scopeViolation(disallowed)
            }
        }
        return persisted
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
