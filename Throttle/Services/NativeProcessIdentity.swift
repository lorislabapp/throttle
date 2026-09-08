import Darwin
import Foundation

/// A PID alone is reusable. Keep the kernel start time and user with it when
/// correlating a session's process with the files it currently has open.
struct NativeProcessIdentity: Equatable, Sendable {
    let pid: pid_t
    let parentPID: pid_t
    let userID: uid_t
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64

    static func capture(_ pid: pid_t) -> Self? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout.size(ofValue: info)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
              info.pbi_uid == geteuid() else { return nil }
        return Self(pid: pid, parentPID: pid_t(info.pbi_ppid), userID: info.pbi_uid,
                    startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec)
    }

    func belongs(to root: Self) -> Bool {
        var current = self
        for _ in 0..<128 {
            if current.pid == root.pid { return current == root }
            guard let parent = Self.capture(current.parentPID), parent.pid != current.pid else { return false }
            current = parent
        }
        return false
    }
}
