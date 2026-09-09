import Darwin
@testable import Throttle
import XCTest

/// Durability claims are worth exactly as much as the crash that tests them.
/// These kill a real writing process, without warning, and then ask the store
/// what it will say about the log it is left with.
final class PlanStoreCrashTests: XCTestCase {

    private var root = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-crash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".throttle/log"),
                                                withIntermediateDirectories: true)
        try """
        { "schema": 1, "projectId": "p", "title": "P", "tasks": [
          { "id": "T1", "order": 0, "title": "Only" }
        ] }
        """.write(to: root.appendingPathComponent(".throttle/plan.json"),
                  atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var log: URL { root.appendingPathComponent(".throttle/log/T1.ndjson") }

    private func event(_ pct: Int) -> TaskEvent {
        TaskEvent(seq: 0, timestamp: Date(timeIntervalSince1970: 1_800_000_000),
                  author: "codex:a", type: .progress, pct: pct)
    }

    /// A writer killed with SIGKILL part-way through a line. The store must
    /// report the log as broken and refuse to build on it — never quietly trim
    /// the torn line and carry on, which would lose the fact that anything
    /// happened at all.
    func testAKilledWriterLeavesARefusalNotASilentRepair() throws {
        let store = PlanStore(projectRoot: root)
        try store.append(event(10), to: "T1")
        try store.append(event(20), to: "T1")
        let intact = try Data(contentsOf: log)

        // A second process appends a line and is killed before it can finish.
        let partial = #"{"seq":3,"at":1800000000,"by":"codex:a","type":"progr"#
        let pid = try spawn("""
        printf '%s' '\(partial)' >> '\(log.path)'; kill -9 $$
        """)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, 0), pid)
        // Swift does not import the wait status macros; the low seven bits are
        // the signal, and zero there means an ordinary exit.
        XCTAssertEqual(status & 0x7f, SIGKILL, "the writer must have died, not exited")

        let torn = try Data(contentsOf: log)
        XCTAssertGreaterThan(torn.count, intact.count, "the partial line is on disk")

        let fresh = PlanStore(projectRoot: root)
        let read = try fresh.events(for: "T1")
        XCTAssertFalse(read.chainValid, "a torn tail is reported, not repaired")
        XCTAssertEqual(read.events.map(\.pct), [10, 20], "the intact prefix is still readable")
        XCTAssertThrowsError(try fresh.append(event(30), to: "T1")) { error in
            XCTAssertEqual(error as? PlanStoreError, .invalidLog("T1"))
        }
        XCTAssertEqual(try Data(contentsOf: log), torn,
                       "a refused append leaves the damaged log exactly as it found it")
    }

    /// The events written before the crash must survive it. This is the claim
    /// F_FULLFSYNC exists for: the drive may hold a flushed write in its own
    /// cache, and a process death must not be able to take it back.
    func testEventsAcknowledgedBeforeTheCrashAreStillThere() throws {
        let pid = try spawn("kill -9 $$")
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)

        let store = PlanStore(projectRoot: root)
        try store.append(event(10), to: "T1")
        let killer = try spawn("kill -9 $$")
        _ = waitpid(killer, &status, 0)

        let read = try PlanStore(projectRoot: root).events(for: "T1")
        XCTAssertEqual(read.events.map(\.pct), [10])
        XCTAssertTrue(read.chainValid)
    }

    /// The lock is what stops two writers interleaving. A holder that dies
    /// without unlocking must not wedge the store: `flock` is released by the
    /// kernel when the descriptor closes, crash included.
    func testALockHeldByAProcessThatDiesIsReleasedByTheKernel() throws {
        let lock = root.appendingPathComponent(".throttle/mutation.lock")
        FileManager.default.createFile(atPath: lock.path, contents: nil)
        // A child takes the exclusive lock, says so, and is killed still holding it.
        let ready = root.appendingPathComponent("held")
        let pid = try spawn("/usr/bin/env python3 -c \"import fcntl,time;"
            + " f=open('\(lock.path)','a'); fcntl.flock(f, fcntl.LOCK_EX);"
            + " open('\(ready.path)','w').write('1'); time.sleep(30)\"")
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !FileManager.default.fileExists(atPath: ready.path),
              ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "the child never took the lock")
        XCTAssertEqual(kill(pid, SIGKILL), 0)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, 0), pid)

        let store = PlanStore(projectRoot: root)
        let written = try store.append(event(42), to: "T1")
        XCTAssertEqual(written.seq, 1, "the store took the lock the dead process had held")
    }

    private func spawn(_ command: String) throws -> pid_t {
        var pid: pid_t = 0
        let words = ["sh", "-c", command]
        let strings = words.map { word in word.withCString { strdup($0) } }
        defer { strings.forEach { free($0) } }
        var arguments = strings + [nil]
        var environment = [strdup("PATH=/usr/bin:/bin"), nil]
        defer { environment.forEach { free($0) } }
        let result = arguments.withUnsafeMutableBufferPointer { argv in
            environment.withUnsafeMutableBufferPointer { envp in
                posix_spawn(&pid, "/bin/sh", nil, nil, argv.baseAddress, envp.baseAddress)
            }
        }
        if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
        return pid
    }
}
