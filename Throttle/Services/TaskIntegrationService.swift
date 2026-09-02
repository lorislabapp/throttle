import Foundation

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
        case dirty, behind, unverified, ungated
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
    let isDirty: Bool
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

    // MARK: - Assess

    static func assess(taskID: String, in repo: URL) throws -> Assessment {
        let worktree = try existingWorktree(taskID, in: repo)
        let base = try sha("HEAD", in: repo)
        let task = try sha("HEAD", in: worktree)

        let dirty = !git(["status", "--porcelain"], in: worktree).output
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let ahead = count(["rev-list", "--count", "\(base)..\(task)"], in: repo)
        let behind = count(["rev-list", "--count", "\(task)..\(base)"], in: repo)

        return Assessment(baseSHA: base, taskSHA: task,
                          behindBy: behind, aheadBy: ahead, isDirty: dirty,
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
        guard let firstSection = result.output.components(separatedBy: "\n\n").first else {
            return .unknown
        }
        let lines = firstSection.split(separator: "\n").map(String.init)
        guard lines.count > 1 else { return .unknown }
        // First line is the tree OID; the rest are the conflicting paths.
        let paths = lines.dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return paths.isEmpty ? .unknown : .conflicted(Array(paths))
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
    @discardableResult
    static func rebase(taskID: String, in repo: URL) throws -> Assessment {
        let worktree = try existingWorktree(taskID, in: repo)
        let before = try assess(taskID: taskID, in: repo)
        guard !before.isDirty else { throw TaskIntegrationError.refused(.dirty) }
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

    // MARK: - Verify

    struct Verdict: Sendable, Equatable {
        let passed: Bool
        let output: String
        let stamp: String
    }

    /// The longest a verification may run before it is killed. A project whose suite
    /// takes longer than this should say so in its own command.
    static let defaultTimeout: TimeInterval = 900
    private static let outputLimit = 4000
    /// Grace period between SIGTERM and SIGKILL. A process that traps or ignores
    /// SIGTERM would otherwise sail past its own timeout with no way out.
    private static let killGracePeriod: TimeInterval = 2
    /// How long `shell` waits for the readability handler to report EOF after the
    /// process has already exited, before reading whatever output was collected.
    /// Bounded, not forever: a leaked grandchild can hold the pipe's write end
    /// open past the process's own exit, and this file already removed one
    /// unbounded wait this run — it is not adding another.
    private static let drainGrace: TimeInterval = 2

    /// Runs the project's verification command in the task's worktree and writes the
    /// `checked` event for it.
    ///
    /// It runs *after* the rebase, on the combined tree, because a semantic conflict
    /// passes the textual merge and only shows up when the two sides are executed
    /// together — evidence produced by the agent before the rebase says nothing about
    /// what is about to be merged.
    ///
    /// Consent is the caller's to obtain: this function runs what it is given.
    @discardableResult
    static func verify(taskID: String, in repo: URL, command: String,
                       timeout: TimeInterval = defaultTimeout,
                       store: PlanStore?, author: String) throws -> Verdict {
        let worktree = try existingWorktree(taskID, in: repo)
        let stamp = try assess(taskID: taskID, in: repo).stamp
        let result = shell(command, in: worktree, timeout: timeout)
        let verdict = Verdict(passed: result.ok, output: String(result.output.suffix(outputLimit)),
                              stamp: stamp)

        try store?.append(TaskEvent(seq: 0, timestamp: Date(), author: author, type: .checked,
                                    ref: stamp, reason: verdict.passed ? nil : verdict.output,
                                    summary: command, passed: verdict.passed),
                          to: taskID)
        return verdict
    }

    /// Runs `command` and collects its combined output without ever blocking on the
    /// pipe closing. `readDataToEndOfFile()` only returns once *every* writer of the
    /// pipe has closed it — a child that ignores SIGTERM, or one that backgrounds a
    /// grandchild holding the inherited stdout/stderr fd, would block that read
    /// forever regardless of any scheduled timeout. Collecting through
    /// `readabilityHandler` instead means this function only ever waits on the
    /// process it launched, never on the pipe draining.
    ///
    /// The deadline escalates: SIGTERM at `timeout`, then SIGKILL after
    /// `killGracePeriod` more if the process is still alive. A killed process comes
    /// back as a failed verdict that says so in its output — never a silent pass,
    /// never an empty failure.
    private static func shell(_ command: String, in directory: URL,
                              timeout: TimeInterval) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let collector = OutputCollector()
        // `readabilityHandler` reports EOF as one final call with empty data.
        // `waitUntilExit()` below returns on its own, independent mechanism, so
        // nothing otherwise guarantees the handler has drained the last chunk by
        // the time the process is observed to have exited — this group is what
        // closes that gap.
        let drained = DispatchGroup()
        drained.enter()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                if collector.consumeEOF() { drained.leave() }
            } else {
                collector.append(chunk)
            }
        }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }

        do {
            try process.run()
        } catch {
            drained.leave()
            return (false, String(describing: error))
        }

        let queue = DispatchQueue.global()
        let sendTerm = DispatchWorkItem {
            guard process.isRunning else { return }
            collector.markTimedOut()
            process.terminate()
        }
        let sendKill = DispatchWorkItem {
            guard process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
        queue.asyncAfter(deadline: .now() + timeout, execute: sendTerm)
        queue.asyncAfter(deadline: .now() + timeout + killGracePeriod, execute: sendKill)

        process.waitUntilExit()
        sendTerm.cancel()
        sendKill.cancel()

        // Bounded: a grandchild that leaked the write end of the pipe can hold it
        // open past the process's own exit, and this file already removed one
        // unbounded wait this run. On expiry this is a truncation, not a hang —
        // the timeout message above already covers the killed case.
        _ = drained.wait(timeout: .now() + drainGrace)

        var output = collector.output
        if collector.timedOut {
            output += "\n[throttle] verification timed out after \(Int(timeout))s and was killed"
        }
        return (process.terminationStatus == 0 && !collector.timedOut, output)
    }

    /// Buffers a subprocess's output as `readabilityHandler` delivers it — on its
    /// own queue, distinct from the queue the timeout escalation runs on — so both
    /// sides go through a lock rather than a plain var.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var hasTimedOut = false
        private var eofSeen = false

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            buffer.append(chunk)
        }

        func markTimedOut() {
            lock.lock(); defer { lock.unlock() }
            hasTimedOut = true
        }

        /// True only the first call — `readabilityHandler` can fire again after
        /// reporting EOF, and the drain group must be left exactly once.
        func consumeEOF() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if eofSeen { return false }
            eofSeen = true
            return true
        }

        var timedOut: Bool {
            lock.lock(); defer { lock.unlock() }
            return hasTimedOut
        }

        var output: String {
            lock.lock(); defer { lock.unlock() }
            return String(bytes: buffer, encoding: .utf8) ?? ""
        }
    }

    // MARK: - git

    private static func existingWorktree(_ taskID: String, in repo: URL) throws -> URL {
        let path = try TaskWorktreeService.path(for: taskID, in: repo)
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw TaskIntegrationError.noWorktree(taskID)
        }
        return path
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
