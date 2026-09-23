import Darwin
import Foundation
@testable import Throttle
import XCTest

final class OwnedProcessTerminationTests: XCTestCase {
    func testReparentingDoesNotChangeTheOwnedIdentity() {
        let before = NativeProcessIdentity(pid: 20, parentPID: 10, userID: 501,
                                           startedSeconds: 100, startedMicroseconds: 123)
        let orphan = NativeProcessIdentity(pid: 20, parentPID: 1, userID: 501,
                                           startedSeconds: 100, startedMicroseconds: 123)
        let reused = NativeProcessIdentity(pid: 20, parentPID: 1, userID: 501,
                                           startedSeconds: 101, startedMicroseconds: 123)
        XCTAssertTrue(OwnedProcessTermination.sameProcess(before, orphan))
        XCTAssertFalse(OwnedProcessTermination.sameProcess(before, reused))
    }

    func testNeverCapturesThrottleItselfForTermination() throws {
        let identity = try XCTUnwrap(NativeProcessIdentity.capture(getpid()))
        XCTAssertNil(OwnedProcessTermination.capture(roots: [identity]))
    }

    func testTermIgnoringOrphanIsKilledWithoutTouchingAnotherSession() throws {
        let fixture = try launchFixture(ignoresTerm: true)
        let unrelated = try launchFixture(ignoresTerm: false)
        XCTAssertEqual(OwnedProcessTermination.stop(fixture.scope, grace: 0.1), .stopped)
        XCTAssertTrue(fixture.scope.members.allSatisfy { member in
            guard let current = NativeProcessIdentity.capture(member.identity.pid) else { return true }
            return !OwnedProcessTermination.sameProcess(current, member.identity)
        })
        let stillAlive = try XCTUnwrap(NativeProcessIdentity.capture(unrelated.root.pid))
        XCTAssertTrue(OwnedProcessTermination.sameProcess(stillAlive, unrelated.root))
    }

    func testSuspendedGroupCanExitAndNoReplacementPIDIsAccepted() throws {
        let fixture = try launchFixture(ignoresTerm: false)
        let wrong = NativeProcessIdentity(pid: fixture.root.pid, parentPID: fixture.root.parentPID,
                                          userID: fixture.root.userID,
                                          startedSeconds: fixture.root.startedSeconds + 1,
                                          startedMicroseconds: fixture.root.startedMicroseconds)
        XCTAssertNil(OwnedProcessTermination.capture(roots: [wrong]))
        XCTAssertEqual(kill(-fixture.root.pid, SIGSTOP), 0)
        XCTAssertEqual(OwnedProcessTermination.stop(fixture.scope, grace: 0.1), .stopped)
    }

    func testObservedGroupDriftPreventsAnAutomaticStopReceipt() throws {
        let fixture = try launchFixture(ignoresTerm: false)
        let unusedGroup: pid_t = 1_000_000
        XCTAssertEqual(kill(-unusedGroup, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        let changed = OwnedProcessTermination.Scope(members: fixture.scope.members.map {
            OwnedProcessTermination.Member(identity: $0.identity, group: unusedGroup)
        })
        // Model an observed move away from the captured group. Only the owned
        // identities may be signalled; an empty old scope is still not a receipt.
        XCTAssertEqual(OwnedProcessTermination.stop(changed, grace: 0), .failed(
            "The session changed process scope while stopping. Review remaining processes before continuing."))
    }

    func testUnreapedZombieIsAnExitReceiptUntilItsParentReaps() throws {
        // The child stops itself so it can be captured alive, then exits once
        // continued. This test is its parent and deliberately does not reap it
        // until the end, exactly like a starved SwiftTerm exit handler.
        let pid = try spawnGroup("kill -STOP $$; exit 0")
        addTeardownBlock { var status: Int32 = 0; _ = waitpid(pid, &status, WNOHANG) }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while NativeProcessIdentity.capture(pid) == nil || getpgid(pid) != pid,
              ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        // CONT sent before the shell has stopped itself would be lost, and the
        // shell would then stop forever: wait for the kernel to report SSTOP.
        while OwnedProcessTermination.kernelState(of: pid) != SSTOP,
              ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let root = try XCTUnwrap(NativeProcessIdentity.capture(pid))
        let scope = try XCTUnwrap(OwnedProcessTermination.capture(roots: [root]))
        XCTAssertEqual(OwnedProcessTermination.kernelState(of: pid), SSTOP)
        XCTAssertFalse(OwnedProcessTermination.isZombie(pid), "A stopped process is alive, not a zombie")
        XCTAssertEqual(kill(pid, SIGCONT), 0)
        while !OwnedProcessTermination.isZombie(pid), ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(OwnedProcessTermination.isZombie(pid), "The child must have exited without being reaped")
        XCTAssertEqual(kill(-pid, 0), -1, "The unreaped group still exists for the kernel")
        XCTAssertNotEqual(errno, ESRCH)
        XCTAssertEqual(OwnedProcessTermination.stop(scope, grace: 0.05, exitTimeout: 0.05), .stopped,
                       "An exited child must be confirmed without waiting for its parent to reap it")
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, 0), pid)
        XCTAssertFalse(OwnedProcessTermination.isZombie(pid))
        XCTAssertEqual(kill(-pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    private func launchFixture(ignoresTerm: Bool) throws -> (
        root: NativeProcessIdentity, scope: OwnedProcessTermination.Scope
    ) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready")
        let childReady = directory.appendingPathComponent("child-ready")
        let child = ignoresTerm ? "trap '' TERM; " : ""
        let childCommand = child + "printf ready > '\(childReady.path)'; while :; do /bin/sleep 1; done"
        let quotedChild = "'" + childCommand.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "trap 'exit 0' TERM; /bin/sh -c \(quotedChild) & "
            + "printf ready > '\(ready.path)'; wait"
        let pid = try spawnGroup(command)
        let root = try XCTUnwrap(NativeProcessIdentity.capture(pid))
        addTeardownBlock {
            if let current = NativeProcessIdentity.capture(pid),
               OwnedProcessTermination.sameProcess(current, root), getpgid(pid) == pid, pid != getpgrp() {
                kill(-pid, SIGKILL)
            }
        }
        // Match SwiftTerm's asynchronous child reaper. A zombie cannot disappear
        // from a process group until its parent has collected its exit status.
        DispatchQueue.global().async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !FileManager.default.fileExists(atPath: childReady.path),
              ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let scope = try XCTUnwrap(OwnedProcessTermination.capture(roots: [root]))
        addTeardownBlock { _ = OwnedProcessTermination.stop(scope, grace: 0.05) }
        XCTAssertGreaterThanOrEqual(scope.members.count, 2, "Capture must include the real child, not only its shell")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: childReady.path))
        return (root, scope)
    }

    private func spawnGroup(_ command: String) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor: Int32 in 0...2 {
            posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", O_RDWR, 0)
        }
        let words: [String] = ["sh", "-c", command]
        let strings = words.map { word in word.withCString { strdup($0) } }
        defer { strings.forEach { free($0) } }
        var arguments = strings + [nil]
        var environment = [strdup("PATH=/usr/bin:/bin"), nil]
        defer { environment.forEach { free($0) } }
        var pid: pid_t = 0
        let result = arguments.withUnsafeMutableBufferPointer { argv in
            environment.withUnsafeMutableBufferPointer { envp in
                posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv.baseAddress, envp.baseAddress)
            }
        }
        if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
        return pid
    }
}
