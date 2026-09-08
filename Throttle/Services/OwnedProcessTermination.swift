import Darwin
import Foundation

/// Stops a captured local process scope. Keep the identities and process groups
/// after TERM: a surviving child may have been reparented by the time KILL runs.
/// This is not a sandbox and does not establish ownership of detached daemons.
enum OwnedProcessTermination {
    enum Outcome: Sendable, Equatable {
        case stopped
        case failed(String)
    }

    struct Member: Sendable {
        let identity: NativeProcessIdentity
        let group: pid_t
    }

    struct Scope: Sendable {
        let members: [Member]
        var groups: Set<pid_t> { Set(members.map(\.group)) }
    }

    static func sameProcess(_ lhs: NativeProcessIdentity, _ rhs: NativeProcessIdentity) -> Bool {
        lhs.pid == rhs.pid && lhs.userID == rhs.userID
            && lhs.startedSeconds == rhs.startedSeconds && lhs.startedMicroseconds == rhs.startedMicroseconds
    }

    /// Capture before sending Ctrl-D, exit, or any signal. Missing/changed roots,
    /// inaccessible descendants and truncated process lists do not form a scope.
    static func capture(roots: [NativeProcessIdentity]) -> Scope? {
        guard !roots.isEmpty else { return Scope(members: []) }
        var members: [Member] = []
        var visited = Set<pid_t>()
        var pending = roots
        while let identity = pending.popLast() {
            guard identity.pid != getpid(), members.count < 256,
                  let current = NativeProcessIdentity.capture(identity.pid), sameProcess(current, identity) else {
                return nil
            }
            guard visited.insert(identity.pid).inserted else { continue }
            let group = getpgid(identity.pid)
            guard group > 1, group != getpgrp(), let children = childPIDs(of: identity.pid) else { return nil }
            members.append(Member(identity: current, group: group))
            for pid in children {
                if let child = NativeProcessIdentity.capture(pid) {
                    guard child.parentPID == identity.pid else { return nil }
                    pending.append(child)
                } else if kill(pid, 0) == 0 || errno != ESRCH {
                    return nil
                }
            }
        }
        guard roots.allSatisfy({ root in
            NativeProcessIdentity.capture(root.pid).map { sameProcess($0, root) } == true
        }) else { return nil }
        return Scope(members: members)
    }

    /// Synchronous on purpose: call from a worker task, never from the UI actor.
    /// The caller retains its terminal and blocks replacement until this returns
    /// stopped. A sent signal by itself is not a successful stop.
    static func stop(_ scope: Scope, grace: TimeInterval = 1.5, exitTimeout: TimeInterval = 2) -> Outcome {
        guard scope.members.allSatisfy({ $0.group > 1 && $0.group != getpgrp() }) else {
            return .failed("Cannot stop a process group shared with Throttle.")
        }
        var scopeChanged = hasGroupDrift(scope)
        for group in scope.groups {
            signalGroup(group, signal: SIGTERM, scope: scope)
            // A suspended process must run to handle TERM. SIGKILL below remains
            // the escalation for a process that ignores it.
            signalGroup(group, signal: SIGCONT, scope: scope)
        }
        if awaitExit(scope, within: grace, scopeChanged: &scopeChanged) {
            return completion(scopeChanged: scopeChanged)
        }
        for group in scope.groups { signalGroup(group, signal: SIGKILL, scope: scope) }
        // A captured child may have moved to another group after capture. Signal
        // only that exact still-owned identity, never a replacement using its PID.
        for member in scope.members where stillRunning(member.identity) {
            if let current = NativeProcessIdentity.capture(member.identity.pid), sameProcess(current, member.identity) {
                kill(member.identity.pid, SIGKILL)
            }
        }
        guard awaitExit(scope, within: exitTimeout, scopeChanged: &scopeChanged) else {
            return .failed("Session stop could not be confirmed. No replacement session was started.")
        }
        return completion(scopeChanged: scopeChanged)
    }

    private static func completion(scopeChanged: Bool) -> Outcome {
        scopeChanged
            ? .failed("The session changed process scope while stopping. Review remaining processes before continuing.")
            : .stopped
    }

    private static func hasGroupDrift(_ scope: Scope) -> Bool {
        scope.members.contains { member in
            guard let current = NativeProcessIdentity.capture(member.identity.pid),
                  sameProcess(current, member.identity) else { return false }
            let group = getpgid(member.identity.pid)
            return group > 1 && group != member.group
        }
    }

    private static func signalGroup(_ group: pid_t, signal: Int32, scope: Scope) {
        guard group > 1, group != getpgrp(), scope.members.contains(where: { member in
            guard member.group == group,
                  let current = NativeProcessIdentity.capture(member.identity.pid),
                  sameProcess(current, member.identity) else { return false }
            return getpgid(member.identity.pid) == group
        }) else { return }
        // At least one captured member still anchors this group. If all anchors
        // have vanished, an occupied group number is unknown, never safe to kill.
        kill(-group, signal)
    }

    private static func stillRunning(_ identity: NativeProcessIdentity) -> Bool {
        guard let current = NativeProcessIdentity.capture(identity.pid) else {
            // An inaccessible PID is unknown, not an exit receipt.
            return kill(identity.pid, 0) == 0 || errno != ESRCH
        }
        return sameProcess(current, identity)
    }

    private static func awaitExit(_ scope: Scope, within duration: TimeInterval, scopeChanged: inout Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, duration)
        repeat {
            // Sticky even if that member subsequently exits: it may have left
            // descendants outside the captured groups. Never certify that scope.
            scopeChanged = scopeChanged || hasGroupDrift(scope)
            let membersGone = scope.members.allSatisfy { !stillRunning($0.identity) }
            let groupsGone = scope.groups.allSatisfy { group in
                kill(-group, 0) == -1 && errno == ESRCH
            }
            if membersGone && groupsGone { return true }
            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.02)
        } while true
    }

    private static func childPIDs(of pid: pid_t) -> [pid_t]? {
        errno = 0
        let requested = proc_listchildpids(pid, nil, 0)
        // Unlike proc_listpids, this wrapper returns a PID count, not bytes.
        guard requested >= 0, requested <= 4096, errno == 0 else { return nil }
        var buffer = [pid_t](repeating: 0, count: Int(requested) + 16)
        errno = 0
        let copied = buffer.withUnsafeMutableBytes {
            proc_listchildpids(pid, $0.baseAddress, Int32($0.count))
        }
        guard copied >= 0, copied < buffer.count, errno == 0 else { return nil }
        return Array(buffer.prefix(Int(copied))).filter { $0 > 1 }
    }
}
