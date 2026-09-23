import Darwin
import Foundation

extension TaskIntegrationService {
    /// Keep the direct child unreaped until escalation ends. Its PID remains an
    /// anchor for the group; a delayed timer cannot signal a recycled group ID.
    final class ChildControl: @unchecked Sendable {
        let readFD: Int32
        let leadsOwnGroup: Bool
        let pid: pid_t
        private let lock = NSLock()
        private(set) var waitFailure: String?
        private var exited = false
        private var reaped = false

        init(pid: pid_t, readFD: Int32) {
            self.pid = pid
            self.readFD = readFD
            let group = getpgid(pid)
            leadsOwnGroup = pid > 1 && group == pid && group != getpgrp()
        }

        @discardableResult
        func signal(_ sig: Int32, onInterrupt: () -> Void = {}) -> SignalOutcome {
            lock.lock(); defer { lock.unlock() }
            guard !reaped else { return .nothing }
            // A successful waitid does not reap: it also distinguishes an exit
            // already in the kernel from a timeout racing the observing thread.
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT | WNOHANG) == 0,
               info.si_pid == pid, Self.isExit(info.si_code) {
                exited = true
            }
            let target = leadsOwnGroup ? -pid : pid
            guard leadsOwnGroup || !exited, kill(target, sig) == 0 else { return .nothing }
            if !exited { onInterrupt() }
            return SignalOutcome(sent: true, interruptedTheRun: !exited)
        }

        /// No group is UNKNOWN, not proof of an empty group. A retained zombie
        /// leader has exited and anchors identity without doing further work.
        var groupIsEmpty: Bool {
            lock.lock(); defer { lock.unlock() }
            guard leadsOwnGroup, !reaped else { return false }
            return (kill(-pid, 0) == -1 && errno == ESRCH) || OwnedProcessTermination.holdsOnlyZombies(pid)
        }

        @discardableResult
        func awaitEmptyGroup(within grace: TimeInterval) -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + max(0, grace)
            while !groupIsEmpty {
                if ProcessInfo.processInfo.systemUptime >= deadline { return false }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return true
        }

        /// Observe exit without releasing the PID. Only this child's parent may
        /// later reap it, after every timer has lost signal authority.
        func waitUntilExit() -> Int32? {
            var info = siginfo_t()
            var result: Int32
            repeat {
                info = siginfo_t()
                result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
                // Darwin can expose the spawn suspension as CLD_STOPPED. A PID
                // in siginfo is not by itself an exit observation. Keep waiting.
                if result == 0, !Self.isExit(info.si_code) { Thread.sleep(forTimeInterval: 0.01) }
            } while (result == -1 && errno == EINTR) || (result == 0 && !Self.isExit(info.si_code))
            let failureCode = errno
            lock.lock(); defer { lock.unlock() }
            guard result == 0, info.si_pid == pid else {
                waitFailure = "waitid result=\(result) errno=\(failureCode) "
                    + "returned_pid=\(info.si_pid) expected_pid=\(pid)"
                // Ownership could no longer be established. Never send another
                // signal using this numeric PID, and do not invent an exit status.
                reaped = true
                return nil
            }
            exited = true
            return info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
        }

        private static func isExit(_ code: Int32) -> Bool {
            code == CLD_EXITED || code == CLD_KILLED || code == CLD_DUMPED
        }

        @discardableResult
        func reap() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !reaped, exited else { return false }
            reaped = true
            var status: Int32 = 0
            var result = waitpid(pid, &status, WNOHANG)
            while result == -1 && errno == EINTR { result = waitpid(pid, &status, WNOHANG) }
            return result == pid
        }
    }
}
