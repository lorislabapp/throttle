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
    /// How long `shell` waits for the pipe to report EOF after the child has already
    /// exited, before reading whatever output was collected.
    /// Bounded, not forever: killing the child's whole process group closes the
    /// ordinary leak, but a grandchild that called `setsid` for itself left that
    /// group and can still hold the pipe's write end open.
    private static let drainGrace: TimeInterval = 2

    private static let shellPath = "/bin/sh"

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
    /// pipe closing. Reading to end-of-file only returns once *every* writer of the
    /// pipe has closed it — a child that ignores SIGTERM, or one that backgrounds a
    /// grandchild holding the inherited stdout/stderr fd, would block that read
    /// forever regardless of any scheduled timeout. Collecting incrementally instead
    /// means this function only ever waits on the process it launched, never on the
    /// pipe draining.
    ///
    /// The deadline escalates: SIGTERM at `timeout`, then SIGKILL after
    /// `killGracePeriod` more if the child is still alive. A killed run comes back as
    /// a failed verdict that says so in its output — never a silent pass, never an
    /// empty failure.
    ///
    /// Both signals reach the child's whole process group, because `spawn` below made
    /// it the leader of one. `Process` cannot: it hands the child the launching
    /// process's own group, so the only pid it could ever signal was the shell's, and
    /// `/bin/sh -c "swift test"` killed at its deadline left the compiler and the test
    /// binaries running — holding this pipe open and, on a 16 GB machine, the RAM with
    /// it. That is why this is `posix_spawn`.
    private static func shell(_ command: String, in directory: URL,
                              timeout: TimeInterval) -> (ok: Bool, output: String) {
        let child: ChildControl
        do {
            child = try spawn(command, in: directory)
        } catch {
            return (false, String(describing: error))
        }

        let collector = OutputCollector()
        // The wait below returns on its own, independent mechanism, so nothing
        // otherwise guarantees the reader has taken the last chunk by the time the
        // child is observed to have exited — this group is what closes that gap.
        let drained = DispatchGroup()
        drained.enter()
        let reader = PipeReader(descriptor: child.readFD, into: collector, drained: drained)

        let queue = DispatchQueue.global()
        let sendTerm = DispatchWorkItem {
            if child.signal(SIGTERM) { collector.markTimedOut() }
        }
        let sendKill = DispatchWorkItem { _ = child.signal(SIGKILL) }
        queue.asyncAfter(deadline: .now() + timeout, execute: sendTerm)
        queue.asyncAfter(deadline: .now() + timeout + killGracePeriod, execute: sendKill)

        let status = child.waitUntilExit()
        sendTerm.cancel()
        sendKill.cancel()

        // Bounded: see `drainGrace`. On expiry this is a truncation, not a hang.
        _ = drained.wait(timeout: .now() + drainGrace)
        reader.finish(within: drainGrace)
        // Balances the `enter` above when EOF never came, so the group is never
        // deallocated mid-flight. `consumeEOF` makes the leave happen exactly once
        // whichever side gets there first.
        if collector.consumeEOF() { drained.leave() }

        return verdictText(collector, child: child, status: status, timeout: timeout)
    }

    /// Drains the read end of the pipe on its own queue until EOF, and owns that
    /// descriptor's lifetime.
    ///
    /// A `DispatchSource` rather than `FileHandle.readabilityHandler`: the handler can
    /// fire once more after being cleared, and `availableData` on a descriptor that
    /// has since been closed raises `NSFileHandleOperationException` — an uncatchable
    /// Objective-C exception in the middle of a verification.
    private final class PipeReader {
        private let descriptor: Int32
        private let source: DispatchSourceRead
        private let stopped: DispatchSemaphore

        init(descriptor: Int32, into collector: OutputCollector, drained: DispatchGroup) {
            self.descriptor = descriptor
            let stopped = DispatchSemaphore(value: 0)
            self.stopped = stopped
            let queue = DispatchQueue(label: "com.lorislab.throttle.verify-output")
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            self.source = source
            source.setEventHandler {
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                let count = read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    collector.append(Data(buffer[0..<count]))
                    return
                }
                if count < 0 && (errno == EINTR || errno == EAGAIN) { return }
                if collector.consumeEOF() { drained.leave() }
                source.cancel()
            }
            source.setCancelHandler { stopped.signal() }
            source.resume()
        }

        /// Stops reading and closes the descriptor — on the caller's thread, and only
        /// once libdispatch has confirmed through the cancel handler that the event
        /// handler will not run again.
        ///
        /// The confirmation is the whole point. Closing *from* the cancel handler let
        /// the close land after `shell` had already returned, by which time the process
        /// had handed that descriptor number to the next `Pipe` git was reading — and
        /// a `read` blocked on a descriptor closed under it never returns on Darwin.
        /// The symptom was a later, unrelated git call hanging for ever, with nothing
        /// in its own stack to explain why.
        ///
        /// On the timeout the descriptor is leaked rather than closed: one leaked
        /// descriptor is cheaper than closing somebody else's.
        func finish(within grace: TimeInterval) {
            source.cancel()
            guard stopped.wait(timeout: .now() + grace) == .success else { return }
            close(descriptor)
        }
    }

    /// Turns what the child left behind into the pair `shell` returns. Split out only
    /// so `shell` stays one readable sequence.
    private static func verdictText(_ collector: OutputCollector, child: ChildControl,
                                    status: Int32?,
                                    timeout: TimeInterval) -> (ok: Bool, output: String) {
        var output = collector.output
        if collector.timedOut {
            output += "\n[throttle] verification timed out after \(Int(timeout))s and was killed"
            output += child.leadsOwnGroup
                ? " — the command and every process it started went with it."
                : " — only the shell could be signalled, so processes it started may still be running."
        }
        guard let status else {
            output += "\n[throttle] the verification process could not be waited for,"
                + " so its result is unknown and is reported as a failure."
            return (false, output)
        }
        return (status == 0 && !collector.timedOut, output)
    }

    /// Why a verification never got as far as running.
    private struct SpawnFailure: Error, CustomStringConvertible {
        let what: String
        let code: Int32
        var description: String {
            "[throttle] could not start the verification: \(what) failed"
                + " (\(String(cString: strerror(code))))"
        }
    }

    /// `$1` is the directory and `$2` the command, each its own argv entry, so
    /// neither is ever re-parsed as shell syntax here.
    ///
    /// The working directory is set by the shell rather than by
    /// `posix_spawn_file_actions_addchdir_np`, which is deprecated as of macOS 26
    /// while its replacement is only available from macOS 26 — and this app ships to
    /// 14. `exec` means the wrapper costs no extra process: the shell that ends up
    /// running the command *is* the one `posix_spawn` put in its own group.
    private static let chdirWrapper = """
        cd -- "$1" || { echo "[throttle] cannot enter $1" >&2; exit 127; }; exec /bin/sh -c "$2"
        """

    /// Spawns `/bin/sh` as the leader of a brand-new process group, with both output
    /// streams on one pipe.
    ///
    /// `POSIX_SPAWN_SETPGROUP` with a pgroup of 0 is the supported way to say "the
    /// child leads its own group". Whether the kernel actually did it is *asked*, not
    /// assumed — see `ChildControl.leadsOwnGroup`.
    private static func spawn(_ command: String, in directory: URL) throws -> ChildControl {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw SpawnFailure(what: "pipe", code: errno) }
        let readFD = fds[0]
        let writeFD = fds[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addclose(&actions, readFD)
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, writeFD)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var argv: [UnsafeMutablePointer<CChar>?] =
            [shellPath, "-c", chdirWrapper, "throttle-verify", directory.path, command]
                .map { strdup($0) }
        argv.append(nil)

        var pid: pid_t = -1
        let code = posix_spawn(&pid, shellPath, &actions, &attributes, &argv, environ)

        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
        for argument in argv { free(argument) }
        // The parent's copy of the write end must go, or the pipe never reports EOF.
        close(writeFD)

        guard code == 0 else {
            close(readFD)
            throw SpawnFailure(what: "posix_spawn", code: code)
        }
        return ChildControl(pid: pid, readFD: readFD)
    }

    /// Owns a spawned child's pid, and the one rule that keeps this file safe: a
    /// signal and the `waitpid` that reaps that pid are mutually exclusive, so a
    /// signal can never land on a pid the kernel has already handed to something else.
    private final class ChildControl: @unchecked Sendable {
        let readFD: Int32
        /// True only when the kernel confirmed this pid leads a process group of its
        /// own, and that group is not Throttle's. `kill(-pid, …)` is used only then:
        /// negating a pid that had merely inherited the launching process's group
        /// would signal Throttle itself, and kill the app.
        let leadsOwnGroup: Bool
        private let pid: pid_t
        private let lock = NSLock()
        private var reaped = false

        init(pid: pid_t, readFD: Int32) {
            self.pid = pid
            self.readFD = readFD
            let group = getpgid(pid)
            leadsOwnGroup = pid > 1 && group == pid && group != getpgrp()
        }

        /// Signals the child's whole process group when it leads one, and the child
        /// alone when it does not. Returns whether anything was signalled.
        @discardableResult
        func signal(_ sig: Int32) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !reaped else { return false }
            kill(leadsOwnGroup ? -pid : pid, sig)
            return true
        }

        /// Blocks until the child exits, then reaps it. Nil when it could not be
        /// waited for at all, which the caller reports rather than reading as a pass.
        ///
        /// `waitid(…, WNOWAIT)` waits *without* consuming the child, so the pid stays
        /// this process's for the whole wait and `signal` above stays safe throughout.
        /// The reap that follows is fenced by the same lock, after which `signal`
        /// declines — there is no window in which both could run.
        func waitUntilExit() -> Int32? {
            var info = siginfo_t()
            var waited = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
            while waited == -1 && errno == EINTR {
                waited = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
            }
            lock.lock()
            reaped = true
            lock.unlock()
            guard waited == 0 else { return nil }

            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) == -1 && errno == EINTR {}
            // `WIFEXITED`/`WEXITSTATUS` are C macros with no Swift counterpart: the
            // low seven bits carry the terminating signal, and are zero on a normal
            // exit, in which case the status is the next eight.
            return (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
        }
    }

    /// Buffers a subprocess's output as the read source delivers it — on its own
    /// queue, distinct from the queue the timeout escalation runs on — so both sides
    /// go through a lock rather than a plain var.
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

        /// True only the first call. Both the read source and `shell`'s own tail
        /// reach for it, and the drain group must be left exactly once.
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
