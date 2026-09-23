import Darwin
import Foundation

/// Identity recorded while the child waits for admission, before project code runs.
/// It identifies the root process, not an exhaustive descendant scope.
struct TaskVerificationProcess: Codable, Equatable, Sendable {
    let identity: NativeProcessIdentity
    let group: pid_t
    let bootSession: UUID

    enum Observation: String, Sendable {
        case sameRootPresent = "ROOT_PRESENT"
        case rootExited = "ROOT_EXITED_DESCENDANTS_UNKNOWN"
        case pidReused = "PID_REUSED_DESCENDANTS_UNKNOWN"
        case differentBoot = "DIFFERENT_BOOT_EXTERNAL_EFFECTS_UNKNOWN"
        case unavailable = "UNAVAILABLE"
    }

    var isValid: Bool {
        identity.pid > 1 && group == identity.pid && identity.startedSeconds > 0
            && identity.startedMicroseconds < 1_000_000
    }

    static func captureAdmittedChild(_ pid: pid_t) -> Self? {
        guard let identity = NativeProcessIdentity.capture(pid),
              identity.parentPID == getpid(), getpgid(pid) == pid, pid != getpgrp(),
              let boot = currentBootSession() else { return nil }
        return Self(identity: identity, group: pid, bootSession: boot)
    }

    /// Read-only diagnostic. None of these results authorizes signalling,
    /// acknowledging completion, replaying an effect, or clearing a lease.
    func observe() -> Observation {
        guard let boot = Self.currentBootSession() else { return .unavailable }
        guard boot == bootSession else { return .differentBoot }
        if let current = NativeProcessIdentity.capture(identity.pid) {
            return OwnedProcessTermination.sameProcess(current, identity) ? .sameRootPresent : .pidReused
        }
        if OwnedProcessTermination.isZombie(identity.pid) { return .rootExited }
        return kill(identity.pid, 0) == -1 && errno == ESRCH ? .rootExited : .unavailable
    }

    static func currentBootSession() -> UUID? {
        var buffer = [UInt8](repeating: 0, count: 64)
        var size = buffer.count
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0,
              size > 1, size <= buffer.count, buffer[size - 1] == 0,
              let value = String(bytes: buffer.prefix(size - 1), encoding: .utf8) else { return nil }
        return UUID(uuidString: value)
    }
}
