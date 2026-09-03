import Foundation

/// The verification half of `TaskIntegrationService`, split into its own file to
/// stay under SwiftLint's `file_length`. It is one concern anyway: everything here
/// is about running a project's own command in a task's worktree and turning what
/// came back into a stamped verdict.
extension TaskIntegrationService {

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
    ///
    /// Both signals reach `/bin/sh` and nothing else. `Process` gives the child the
    /// launching process's own process group, so signalling the group would signal
    /// Throttle; putting the child in a group of its own needs `posix_spawn` with
    /// `POSIX_SPAWN_SETPGROUP`, which this lot does not do. The consequence is real
    /// and is stated rather than hidden: a killed `swift test` leaves its compiler
    /// and test processes running, which is also why `drainGrace` is bounded — those
    /// survivors hold the write end of the pipe open. The timeout message says so to
    /// the user.
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
            // The shell's pid, never `-pgid`: the child inherited *Throttle's* process
            // group, so negating this would kill the app along with the test suite.
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
            output += "\n[throttle] verification timed out after \(Int(timeout))s and was killed."
                + " Only the shell was signalled — processes it started may still be running."
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
}
