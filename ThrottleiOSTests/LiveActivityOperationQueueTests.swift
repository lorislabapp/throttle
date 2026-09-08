@testable import Throttle
import XCTest

@MainActor
final class LiveActivityOperationQueueTests: XCTestCase {
    func testRevocationRejectsAnUpdateStillWaitingInTheQueue() async {
        let queue = LiveActivityOperationQueue()
        let probe = ActivityOperationProbe()
        queue.retire(ids: ["previous"]) { _ in await probe.pause() }
        await probe.waitUntilPaused()
        queue.update(id: "account-A") { await probe.record("update-A") }
        queue.retire(ids: ["account-A"]) { ids in await probe.record(ids.sorted().joined()) }

        XCTAssertTrue(queue.isRetiring("account-A"))
        probe.resume()
        await queue.pendingTask?.value
        XCTAssertEqual(probe.events, ["account-A"])
    }

    func testRevocationWaitsForAnUpdateAlreadyInFlight() async {
        let queue = LiveActivityOperationQueue()
        let probe = ActivityOperationProbe()
        queue.update(id: "account-A") {
            await probe.pause()
            await probe.record("updated-A")
        }
        await probe.waitUntilPaused()
        queue.retire(ids: ["account-A"]) { _ in await probe.record("ended-A") }

        XCTAssertTrue(probe.events.isEmpty)
        probe.resume()
        await queue.pendingTask?.value
        XCTAssertEqual(probe.events, ["updated-A", "ended-A"])
    }

    func testOldCleanupDoesNotRevokeTheNewAccountActivity() async {
        let queue = LiveActivityOperationQueue()
        let probe = ActivityOperationProbe()
        queue.update(id: "account-A") { await probe.pause() }
        await probe.waitUntilPaused()
        queue.retire(ids: ["account-A"]) { ids in
            await probe.record("ended-" + ids.sorted().joined())
        }
        queue.supersedeUpdates()
        queue.update(id: "account-B") { await probe.record("updated-B") }

        XCTAssertFalse(queue.isRetiring("account-B"))
        probe.resume()
        await queue.pendingTask?.value
        XCTAssertEqual(probe.events, ["ended-account-A", "updated-B"])
    }

    func testNewSnapshotSupersedesAnOlderQueuedSnapshot() async {
        let queue = LiveActivityOperationQueue()
        let probe = ActivityOperationProbe()
        queue.retire(ids: []) { _ in await probe.pause() }
        await probe.waitUntilPaused()
        queue.update(id: "account-A") { await probe.record("stale") }
        queue.supersedeUpdates()
        queue.update(id: "account-A") { await probe.record("latest") }

        probe.resume()
        await queue.pendingTask?.value
        XCTAssertEqual(probe.events, ["latest"])
    }

    func testRetiredActivityCannotReceiveAFutureUpdate() async {
        let queue = LiveActivityOperationQueue()
        let probe = ActivityOperationProbe()
        queue.retire(ids: ["account-A"]) { _ in await probe.record("ended-A") }
        await queue.pendingTask?.value
        queue.update(id: "account-A") { await probe.record("resurrected-A") }
        await queue.pendingTask?.value
        XCTAssertEqual(probe.events, ["ended-A"])
    }
}

@MainActor
private final class ActivityOperationProbe {
    private(set) var events: [String] = []
    private var paused: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func record(_ event: String) {
        events.append(event)
    }

    func pause() async {
        await withCheckedContinuation { continuation in
            paused = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilPaused() async {
        guard paused == nil else { return }
        await withCheckedContinuation { observer = $0 }
    }

    func resume() {
        paused?.resume()
        paused = nil
    }
}
