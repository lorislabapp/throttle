@testable import Throttle
import XCTest

/// The store's job is to make the log trustworthy: sequence numbers that only go
/// up, a hash chain that catches a log edited behind Throttle's back, and derived
/// state that can be thrown away without losing anything.
final class PlanStoreTests: XCTestCase {

    private var root = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".throttle"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writePlan(_ json: String) throws {
        try json.write(to: root.appendingPathComponent(".throttle/plan.json"),
                       atomically: true, encoding: .utf8)
    }

    private var twoLeafPlan: String {
        """
        { "schema": 1, "projectId": "p", "title": "P", "tasks": [
          { "id": "P1", "order": 0, "title": "Phase 1" },
          { "id": "T1.1", "parent": "P1", "order": 0, "title": "First" },
          { "id": "T1.2", "parent": "P1", "order": 1, "title": "Second", "dependsOn": ["T1.1"] }
        ] }
        """
    }

    private func event(_ type: TaskEventType, author: String = "codex:a",
                       pct: Int? = nil, summary: String? = nil) -> TaskEvent {
        TaskEvent(seq: 0, timestamp: Date(timeIntervalSince1970: 1_800_000_000),
                  author: author, type: type, pct: pct, summary: summary)
    }

    // MARK: - Log mechanics

    func testAppendAssignsIncreasingSeqAndChainsHashes() throws {
        try writePlan(twoLeafPlan)
        let store = PlanStore(projectRoot: root)

        let first = try store.append(event(.claimed), to: "T1.1")
        let second = try store.append(event(.progress, pct: 40), to: "T1.1")

        XCTAssertEqual(first.seq, 1)
        XCTAssertNil(first.prev, "the first line has nothing to chain to")
        XCTAssertEqual(second.seq, 2)
        XCTAssertNotNil(second.prev)

        let read = try store.events(for: "T1.1")
        XCTAssertEqual(read.events.count, 2)
        XCTAssertTrue(read.chainValid)
        XCTAssertEqual(read.events.last?.pct, 40)
    }

    /// What the chain actually buys: an edit to any line but the last is caught,
    /// because the following line's `prev` no longer matches.
    func testEditedLogBreaksTheChain() throws {
        try writePlan(twoLeafPlan)
        let store = PlanStore(projectRoot: root)
        try store.append(event(.claimed), to: "T1.1")
        try store.append(event(.progress, pct: 40), to: "T1.1")
        try store.append(event(.progress, pct: 70), to: "T1.1")

        let log = root.appendingPathComponent(".throttle/log/T1.1.ndjson")
        let tampered = try String(contentsOf: log, encoding: .utf8)
            .replacingOccurrences(of: "\"pct\":40", with: "\"pct\":95")
        try tampered.write(to: log, atomically: true, encoding: .utf8)

        let read = try store.events(for: "T1.1")
        XCTAssertFalse(read.chainValid)
        XCTAssertEqual(read.events.count, 3, "a broken chain still yields its content")
    }

    /// The chain's known limit, asserted so nobody later mistakes it for proof:
    /// the final line has no successor to vouch for it, so editing it is invisible.
    /// Closing this needs a signature, not a hash — a lot E decision.
    func testEditingTheFinalLineIsNotDetected() throws {
        try writePlan(twoLeafPlan)
        let store = PlanStore(projectRoot: root)
        try store.append(event(.claimed), to: "T1.1")
        try store.append(event(.progress, pct: 40), to: "T1.1")

        let log = root.appendingPathComponent(".throttle/log/T1.1.ndjson")
        let tampered = try String(contentsOf: log, encoding: .utf8)
            .replacingOccurrences(of: "\"pct\":40", with: "\"pct\":95")
        try tampered.write(to: log, atomically: true, encoding: .utf8)

        let read = try store.events(for: "T1.1")
        XCTAssertTrue(read.chainValid)
        XCTAssertEqual(read.events.last?.pct, 95)
    }

    /// A rogue writer that rebuilds every hash produces a log Throttle cannot tell
    /// from a genuine one. The chain is tamper-evidence against careless edits, not
    /// a cryptographic guarantee.
    func testFullyRewrittenChainIsIndistinguishable() throws {
        try writePlan(twoLeafPlan)
        let honest = PlanStore(projectRoot: root)
        try honest.append(event(.claimed), to: "T1.1")
        try honest.append(event(.completed, summary: "real"), to: "T1.1")

        let other = root.appendingPathComponent("forged", isDirectory: true)
        try FileManager.default.createDirectory(at: other.appendingPathComponent(".throttle"),
                                                withIntermediateDirectories: true)
        try twoLeafPlan.write(to: other.appendingPathComponent(".throttle/plan.json"),
                              atomically: true, encoding: .utf8)
        let forger = PlanStore(projectRoot: other)
        try forger.append(event(.claimed), to: "T1.1")
        try forger.append(event(.completed, summary: "invented"), to: "T1.1")

        let forged = try forger.events(for: "T1.1")
        XCTAssertTrue(forged.chainValid)
        XCTAssertEqual(forged.events.last?.summary, "invented")
    }

    func testUnsafeTaskIDIsRefused() throws {
        try writePlan(twoLeafPlan)
        let store = PlanStore(projectRoot: root)
        for bad in ["../escape", "a/b", ".hidden", ""] {
            do {
                _ = try store.append(event(.claimed), to: bad)
                XCTFail("expected \(bad) to be refused")
            } catch let error as PlanStoreError {
                XCTAssertEqual(error, .unsafeTaskID(bad))
            }
        }
    }

    func testMissingPlanThrows() throws {
        let store = PlanStore(projectRoot: root)
        do {
            _ = try store.loadPlan()
            XCTFail("expected a missing plan to throw")
        } catch let error as PlanStoreError {
            guard case .missingPlan = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testUnknownTaskThrows() throws {
        try writePlan(twoLeafPlan)
        let store = PlanStore(projectRoot: root)
        do {
            _ = try store.state(for: "T9.9")
            XCTFail("expected an unknown task to throw")
        } catch let error as PlanStoreError {
            XCTAssertEqual(error, .unknownTask("T9.9"))
        }
    }

    // MARK: - Plan-level resolution

    func testResolveAppliesDependenciesAndRollup() throws {
        try writePlan(twoLeafPlan)
        let store = PlanStore(projectRoot: root)
        try store.append(event(.claimed), to: "T1.1")
        try store.append(event(.completed, summary: "done"), to: "T1.1")

        let (_, states) = try store.resolveAll()
        XCTAssertEqual(states["T1.1"]?.status, .done)
        XCTAssertEqual(states["T1.2"]?.status, .pending, "its dependency is satisfied")
        XCTAssertEqual(states["P1"]?.pct, 50)
    }

    func testDependencyStillBlocksWhenUpstreamIsUnfinished() throws {
        try writePlan(twoLeafPlan)
        let store = PlanStore(projectRoot: root)
        try store.append(event(.claimed), to: "T1.1")

        let (_, states) = try store.resolveAll()
        XCTAssertEqual(states["T1.2"]?.status, .blocked)
        XCTAssertEqual(states["T1.2"]?.blockedReason, "T1.1")
    }

    /// The event-sourcing invariant. If this ever fails, the state files have
    /// quietly become a second source of truth.
    func testStateCacheIsFullyRebuildable() throws {
        try writePlan(twoLeafPlan)
        let store = PlanStore(projectRoot: root)
        try store.append(event(.claimed), to: "T1.1")
        try store.append(event(.progress, pct: 60), to: "T1.1")
        try store.append(event(.evidence, author: "codex:a"), to: "T1.1")

        let before = try store.resolveAll().states
        let stateDir = root.appendingPathComponent(".throttle/state")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateDir.path),
                      "resolve should have written the derived cache")

        try store.discardStateCache()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDir.path))

        let after = try store.resolveAll().states
        XCTAssertEqual(before, after)
    }

    func testReplayIsCachedUntilTheLogChanges() throws {
        try writePlan(twoLeafPlan)
        let store = PlanStore(projectRoot: root)
        try store.append(event(.claimed), to: "T1.1")

        let first = try store.events(for: "T1.1").events.count
        let second = try store.events(for: "T1.1").events.count
        XCTAssertEqual(first, second)

        try store.append(event(.progress, pct: 10), to: "T1.1")
        let third = try store.events(for: "T1.1").events.count
        XCTAssertEqual(third, 2, "an append must invalidate the memoised replay")
    }

    func testTaskWithNoLogReadsAsEmpty() throws {
        try writePlan(twoLeafPlan)
        let store = PlanStore(projectRoot: root)
        let read = try store.events(for: "T1.2")
        XCTAssertTrue(read.events.isEmpty)
        XCTAssertTrue(read.chainValid)
    }
}
