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
        // `interruptedTheRun`, not merely `sent`. This item can execute in the
        // microseconds between the child exiting and `sendTerm.cancel()` landing, and
        // if the run left anything alive in its group the signal still goes out and
        // still reports as sent — marking a timeout on that would turn a verification
        // that passed into a failure that claims it ran out of time.
        let sendTerm = DispatchWorkItem {
            if child.signal(SIGTERM).interruptedTheRun { collector.markTimedOut() }
        }
        // No such condition here: a genuine timeout's escalation must reach a group
        // whose leader has already died of the SIGTERM, which is the whole point.
        let sendKill = DispatchWorkItem { child.signal(SIGKILL) }
        queue.asyncAfter(deadline: .now() + timeout, execute: sendTerm)
        queue.asyncAfter(deadline: .now() + timeout + killGracePeriod, execute: sendKill)

        let status = child.waitUntilExit()
        sendTerm.cancel()
        // The escalation is released when the *group* is empty, not when its leader
        // exits. SIGTERM that kills the shell but is trapped or ignored by something
        // it started left that survivor running the moment this cancelled here — the
        // compiler still holding the RAM, which is the case the whole mechanism
        // exists to close. So after a timeout the SIGKILL already scheduled for
        // `killGracePeriod` later is left to fire, and this waits for it to work.
        //
        // Only after a timeout. A command that exited on its own and deliberately
        // left something running behind it has not misbehaved, and killing or waiting
        // for that would be this function inventing a policy nobody asked it for.
        let emptied = collector.timedOut
            ? child.awaitEmptyGroup(within: killGracePeriod + drainGrace)
            : true
        sendKill.cancel()

        // Bounded: see `drainGrace`. On expiry this is a truncation, not a hang.
        _ = drained.wait(timeout: .now() + drainGrace)
        reader.finish(within: drainGrace)
        // Balances the `enter` above when EOF never came, so the group is never
        // deallocated mid-flight. `consumeEOF` makes the leave happen exactly once
        // whichever side gets there first.
        if collector.consumeEOF() { drained.leave() }

        return verdictText(collector, child: child, status: status,
                           timeout: timeout, emptied: emptied)
    }

    /// Turns what the child left behind into the pair `shell` returns. Split out only
    /// so `shell` stays one readable sequence.
    private static func verdictText(_ collector: OutputCollector, child: ChildControl,
                                    status: Int32?, timeout: TimeInterval,
                                    emptied: Bool) -> (ok: Bool, output: String) {
        var output = collector.output
        if collector.timedOut {
            output += "\n[throttle] verification timed out after \(Int(timeout))s and was killed"
            switch (child.leadsOwnGroup, emptied) {
            case (false, _):
                output += " — only the shell could be signalled,"
                    + " so processes it started may still be running."
            case (true, true):
                output += " — the command and every process it started went with it."
            case (true, false):
                output += " — its process group would not empty, so something that left"
                    + " that group may still be running."
            }
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
    /// streams on one pipe, and owns the pipe's two descriptors on every path out.
    private static func spawn(_ command: String, in directory: URL) throws -> ChildControl {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw SpawnFailure(what: "pipe", code: errno) }
        let readFD = fds[0]
        let writeFD = fds[1]
        do {
            let pid = try launch(command, in: directory, writeFD: writeFD)
            // The parent's copy of the write end must go, or the pipe never reports EOF.
            close(writeFD)
            return ChildControl(pid: pid, readFD: readFD)
        } catch {
            close(writeFD)
            close(readFD)
            throw error
        }
    }

    /// The `posix_spawn` itself.
    ///
    /// `POSIX_SPAWN_SETPGROUP` with a pgroup of 0 is the supported way to say "the
    /// child leads its own group". Whether the kernel actually did it is *asked*, not
    /// assumed — see `ChildControl.leadsOwnGroup`.
    ///
    /// `POSIX_SPAWN_CLOEXEC_DEFAULT` closes everything the file actions do not name,
    /// which is what `Foundation.Process` does and what this had been missing.
    /// Without it the project's own command — arbitrary, user-supplied, running for
    /// minutes — inherits every non-close-on-exec descriptor the app holds. The sharp
    /// edge is not privacy but liveness: two projects can integrate at once now, and
    /// project B's child inheriting project A's pipe *write* end means A's pipe never
    /// reports EOF, so a run that succeeded stalls and comes back truncated.
    ///
    /// Every return code is checked. A file action that silently failed to be
    /// recorded would leave the child with the wrong descriptors and nothing but
    /// downstream confusion to say so.
    private static func launch(_ command: String, in directory: URL,
                               writeFD: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        try check("file_actions_init", posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Named explicitly rather than inherited: under `CLOEXEC_DEFAULT` an
        // unspecified descriptor 0 simply would not exist in the child, and a command
        // that reads standard input would see `EBADF` instead of end-of-input. It is
        // also not this app's stdin — a verification has no business consuming it.
        try check("addopen stdin", posix_spawn_file_actions_addopen(
            &actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check("adddup2 stdout",
                  posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO))
        try check("adddup2 stderr",
                  posix_spawn_file_actions_adddup2(&actions, writeFD, STDERR_FILENO))

        var attributes: posix_spawnattr_t?
        try check("spawnattr_init", posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        try check("setflags", posix_spawnattr_setflags(&attributes, flags))
        try check("setpgroup", posix_spawnattr_setpgroup(&attributes, 0))

        var argv: [UnsafeMutablePointer<CChar>?] =
            [shellPath, "-c", chdirWrapper, "throttle-verify",
             directory.path(percentEncoded: false), command]
                .map { strdup($0) }
        argv.append(nil)
        defer { for argument in argv { free(argument) } }

        var pid: pid_t = -1
        let code = posix_spawn(&pid, shellPath, &actions, &attributes, &argv, environ)
        guard code == 0 else { throw SpawnFailure(what: "posix_spawn", code: code) }
        return pid
    }

    /// These all report an errno as their return value rather than through `errno`.
    private static func check(_ what: String, _ code: Int32) throws {
        guard code == 0 else { throw SpawnFailure(what: what, code: code) }
    }
}
