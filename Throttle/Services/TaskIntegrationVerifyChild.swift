import Foundation

/// The three small machines `TaskIntegrationServiceVerify.swift` runs a project's
/// command on: the child process and its group, the pipe it writes to, and the
/// buffer that pipe fills. Split out of that file to stay under SwiftLint's
/// `file_length`; they belong to `shell()` and to nothing else.
///
/// They are nested rather than top-level so the namespace still says who owns them,
/// and internal rather than `private` only because Swift's `private` does not cross
/// files.
extension TaskIntegrationService {

    /// Drains the read end of the pipe on its own queue until EOF, and owns that
    /// descriptor's lifetime.
    ///
    /// A `DispatchSource` rather than `FileHandle.readabilityHandler`: the handler can
    /// fire once more after being cleared, and `availableData` on a descriptor that
    /// has since been closed raises `NSFileHandleOperationException` — an uncatchable
    /// Objective-C exception in the middle of a verification.
    final class PipeReader {
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

    /// What one signal from `ChildControl` did: whether anything received it, and
    /// whether the child itself was still running when it went out.
    ///
    /// A sibling of `ChildControl` rather than a member of it, only because
    /// SwiftLint's `nesting` allows one level and this file is already one deep.
    struct SignalOutcome {
        let sent: Bool
        /// The child had not been reaped, so this interrupted a run in progress rather
        /// than chasing what that run left behind. Only this may be read as a timeout:
        /// a timeout is a statement about the run, and a run that had already finished
        /// did not time out however many stragglers it left.
        let interruptedTheRun: Bool

        static let nothing = SignalOutcome(sent: false, interruptedTheRun: false)
    }

    /// Owns a spawned child's pid, and the one rule that keeps this file safe: a
    /// signal and the `waitpid` that reaps that pid are mutually exclusive, so a
    /// signal can never land on a pid the kernel has already handed to something else.
    final class ChildControl: @unchecked Sendable {
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
        /// alone when it does not.
        ///
        /// The group form outlives the reap on purpose. POSIX keeps a process group id
        /// out of circulation for as long as the group still has members, so `-pid`
        /// cannot land on a stranger once the leader has been reaped — and after the
        /// leader has been reaped is exactly when the survivors are what matters. The
        /// pid form still stops at the reap, because a bare pid *is* reusable.
        ///
        /// That is why the reaped flag comes back in the result rather than gating the
        /// signal. The escalation must still reach a group whose leader is gone; the
        /// *timeout verdict* must not be pronounced over one. Both are read from the
        /// same lock, so the answer cannot change between deciding to signal and
        /// deciding what the signal meant.
        @discardableResult
        func signal(_ sig: Int32) -> SignalOutcome {
            lock.lock(); defer { lock.unlock() }
            let running = !reaped
            guard leadsOwnGroup else {
                guard running else { return .nothing }
                kill(pid, sig)
                return SignalOutcome(sent: true, interruptedTheRun: true)
            }
            guard kill(-pid, 0) == 0 else { return .nothing }
            kill(-pid, sig)
            return SignalOutcome(sent: true, interruptedTheRun: running)
        }

        /// True when nothing is left in the child's process group — or when there was
        /// never a group of its own to ask about, which nothing here can do better
        /// than admit.
        var groupIsEmpty: Bool {
            guard leadsOwnGroup else { return true }
            lock.lock(); defer { lock.unlock() }
            return kill(-pid, 0) != 0
        }

        /// Waits, bounded, for the last member of the group to go. Polled rather than
        /// waited on: these are the child's descendants, not this process's children,
        /// so there is nothing to `wait` for.
        @discardableResult
        func awaitEmptyGroup(within grace: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(grace)
            while !groupIsEmpty {
                if Date() >= deadline { return false }
                Thread.sleep(forTimeInterval: 0.02)
            }
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
            var collected = waitpid(pid, &raw, 0)
            while collected == -1 && errno == EINTR {
                collected = waitpid(pid, &raw, 0)
            }
            // A failed `waitpid` used to leave `raw` at 0 and be read as exit 0 — a
            // silent pass, in a file whose whole doctrine is that there are none.
            guard collected == pid else { return nil }
            // `WIFEXITED`/`WEXITSTATUS` are C macros with no Swift counterpart: the
            // low seven bits carry the terminating signal, and are zero on a normal
            // exit, in which case the status is the next eight.
            return (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
        }
    }

    /// Buffers a subprocess's output as the read source delivers it — on its own
    /// queue, distinct from the queue the timeout escalation runs on — so both sides
    /// go through a lock rather than a plain var.
    final class OutputCollector: @unchecked Sendable {
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
