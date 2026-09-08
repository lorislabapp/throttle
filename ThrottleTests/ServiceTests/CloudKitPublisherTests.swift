import CloudKit
import Foundation
@testable import Throttle
import ThrottleShared
import XCTest

@MainActor
final class CloudKitPublisherTests: XCTestCase {
    func testOptOutDuringAccountCheckCannotReenableOrReplayDisabledSnapshots() async throws {
        let first = CloudPublisherBackendFake(), second = CloudPublisherBackendFake()
        var backends = [first, second]
        let publisher = CloudKitPublisher(makeBackend: { backends.removeFirst() }, minInterval: 0)
        defer { publisher.stop() }
        publisher.publish(snapshot("before opt-in"))
        publisher.start()
        publisher.publish(snapshot("waiting for account"))
        try await eventually { first.accountWaiter != nil }
        publisher.stop()
        publisher.publish(snapshot("after opt-out"))
        try first.resolveAccount(.available)
        await settle()
        XCTAssertTrue(first.saved.isEmpty)
        XCTAssertEqual(first.cancellations, 1)
        publisher.start()
        try await eventually { second.accountWaiter != nil }
        try second.resolveAccount(.available)
        await settle()
        XCTAssertTrue(second.saved.isEmpty)
        publisher.publish(snapshot("fresh opt-in"))
        try await eventually { second.saved.count == 1 }
        XCTAssertEqual(second.saved.map(\.deviceName), ["fresh opt-in"])
        try second.resolveSave()
    }

    func testLateSaveFromOldGenerationCannotReleaseNewSaveOrConsumeItsPendingSnapshot() async throws {
        let first = CloudPublisherBackendFake(), second = CloudPublisherBackendFake()
        var backends = [first, second]
        let publisher = CloudKitPublisher(makeBackend: { backends.removeFirst() }, minInterval: 0)
        defer { publisher.stop() }
        publisher.start()
        try await eventually { first.accountWaiter != nil }
        try first.resolveAccount(.available)
        publisher.publish(snapshot("old generation"))
        try await eventually { first.saved.count == 1 }
        publisher.stop()
        publisher.start()
        try await eventually { second.accountWaiter != nil }
        try second.resolveAccount(.available)
        publisher.publish(snapshot("new in flight"))
        try await eventually { second.saved.count == 1 }
        publisher.publish(snapshot("new pending"))
        // This fake deliberately ignores cancellation, like a late network callback.
        try first.resolveSave()
        await settle()
        XCTAssertEqual(second.saved.map(\.deviceName), ["new in flight"])
        try second.resolveSave()
        try await eventually { second.saved.count == 2 }
        XCTAssertEqual(second.saved.map(\.deviceName), ["new in flight", "new pending"])
        XCTAssertEqual(second.maximumConcurrentSaves, 1)
        try second.resolveSave()
    }

    func testAccountChangeDropsQueuedSnapshotAndRequiresFreshAccountCheck() async throws {
        let first = CloudPublisherBackendFake(), second = CloudPublisherBackendFake()
        var backends = [first, second]
        let center = NotificationCenter()
        let publisher = CloudKitPublisher(makeBackend: { backends.removeFirst() },
                                          notificationCenter: center, minInterval: 0)
        defer { publisher.stop() }
        publisher.start()
        try await eventually { first.accountWaiter != nil }
        publisher.publish(snapshot("previous account"))
        center.post(name: .CKAccountChanged, object: nil)
        try await eventually { second.accountWaiter != nil }
        try first.resolveAccount(.available)
        try second.resolveAccount(.available)
        await settle()
        XCTAssertTrue(first.saved.isEmpty)
        XCTAssertTrue(second.saved.isEmpty)
        XCTAssertEqual(first.cancellations, 1)
        publisher.publish(snapshot("current account"))
        try await eventually { second.saved.count == 1 }
        XCTAssertEqual(second.saved.map(\.deviceName), ["current account"])
        try second.resolveSave()
    }

    func testCancelledDebounceCannotConsumeSnapshotAfterRestart() async throws {
        let first = CloudPublisherBackendFake(), second = CloudPublisherBackendFake()
        var backends = [first, second]
        let delay = CloudPublisherDelayFake()
        let publisher = CloudKitPublisher(makeBackend: { backends.removeFirst() },
            now: { Date(timeIntervalSince1970: 1_000) }, sleep: { try await delay.sleep($0) })
        defer { publisher.stop() }
        publisher.start()
        try await eventually { first.accountWaiter != nil }
        try first.resolveAccount(.available)
        publisher.publish(snapshot("first write"))
        try await eventually { first.saved.count == 1 }
        try first.resolveSave()
        publisher.publish(snapshot("debounced old write"))
        try await eventually { delay.waiter != nil }
        XCTAssertEqual(delay.intervals, [25])
        publisher.stop()
        publisher.start()
        try await eventually { second.accountWaiter != nil }
        try second.resolveAccount(.available)
        publisher.publish(snapshot("current write"))
        try await eventually { second.saved.count == 1 }
        try delay.resolve()
        await settle()
        XCTAssertEqual(first.saved.map(\.deviceName), ["first write"])
        XCTAssertEqual(second.saved.map(\.deviceName), ["current write"])
        try second.resolveSave()
    }

    func testAccountNotificationRevokesBeforeAnAlreadyQueuedFlushCanStart() async throws {
        let first = CloudPublisherBackendFake(), second = CloudPublisherBackendFake()
        var backends = [first, second]
        let center = NotificationCenter()
        let publisher = CloudKitPublisher(makeBackend: { backends.removeFirst() },
                                          notificationCenter: center, minInterval: 0)
        defer { publisher.stop() }
        publisher.start()
        try await eventually { first.accountWaiter != nil }
        try first.resolveAccount(.available)
        await settle()

        // Both calls execute on the main actor before its queued flush can run.
        // The existing CloudKit database now belongs to B, but the queued data is A's.
        publisher.publish(snapshot("account-A private snapshot"))
        first.accountLabel = "account-B"
        center.post(name: .CKAccountChanged, object: nil)
        XCTAssertEqual(first.cancellations, 1, "Account notification must revoke synchronously")

        try await eventually { second.accountWaiter != nil }
        await settle()
        XCTAssertTrue(first.saved.isEmpty, "Old queued data reached save after the account notification")
        XCTAssertTrue(first.savedAccountLabels.isEmpty, "Old account data was submitted under the new account")
        if !first.saved.isEmpty { try first.resolveSave() }
        try second.resolveAccount(.available)
        await settle()
        XCTAssertTrue(second.saved.isEmpty)
        publisher.publish(snapshot("account-B fresh snapshot"))
        try await eventually { second.saved.count == 1 }
        XCTAssertEqual(second.saved.map(\.deviceName), ["account-B fresh snapshot"])
        try second.resolveSave()
    }

    func testUnavailableAccountDiscardsPendingAndRepeatedStartDoesNotDuplicateAccountCheck() async throws {
        let backend = CloudPublisherBackendFake()
        var creations = 0
        let publisher = CloudKitPublisher(makeBackend: { creations += 1; return backend }, minInterval: 0)
        defer { publisher.stop() }
        publisher.start()
        publisher.start()
        publisher.publish(snapshot("unavailable"))
        try await eventually { backend.accountWaiter != nil }
        try backend.resolveAccount(.noAccount)
        await settle()
        publisher.publish(snapshot("still unavailable"))
        await settle()
        XCTAssertEqual(creations, 1)
        XCTAssertTrue(backend.saved.isEmpty)
    }

    func testAuthenticationFailureCancelsAndDropsPendingBeforeRecheckingAccount() async throws {
        let first = CloudPublisherBackendFake(), second = CloudPublisherBackendFake()
        var backends = [first, second]
        let publisher = CloudKitPublisher(makeBackend: { backends.removeFirst() }, minInterval: 0)
        defer { publisher.stop() }
        publisher.start()
        try await eventually { first.accountWaiter != nil }
        try first.resolveAccount(.available)
        publisher.publish(snapshot("in flight"))
        try await eventually { first.saved.count == 1 }
        publisher.publish(snapshot("queued before sign-out"))
        try first.resolveSave(error: CKError(.notAuthenticated))
        try await eventually { second.accountWaiter != nil }
        try second.resolveAccount(.available)
        await settle()
        XCTAssertTrue(second.saved.isEmpty)
        XCTAssertEqual(first.cancellations, 1)
        publisher.publish(snapshot("after recheck"))
        try await eventually { second.saved.count == 1 }
        XCTAssertEqual(second.saved.map(\.deviceName), ["after recheck"])
        try second.resolveSave()
    }

    private func snapshot(_ name: String) -> ThrottleMirrorSnapshot {
        .init(publishedAt: Date(timeIntervalSince1970: 1_000), deviceName: name,
              fiveHour: .init(utilization: 1, resetsAt: nil), sevenDay: .init(utilization: 2, resetsAt: nil),
              sevenDaySonnet: .init(utilization: 0, resetsAt: nil), weeklyTokens: 0, weeklyCostEUR: 0,
              savedTokensThisWeek: 0, sessionCount: 0, tabs: [])
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(predicate(), "The controlled asynchronous operation did not reach its checkpoint")
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

@MainActor
private final class CloudPublisherBackendFake: CloudKitPublishingBackend {
    var accountWaiter: CheckedContinuation<CKAccountStatus, Error>?
    var accountLabel = "account-A"
    private var saveWaiters: [CheckedContinuation<Void, Error>] = []
    private(set) var saved: [ThrottleMirrorSnapshot] = []
    private(set) var savedAccountLabels: [String] = []
    private(set) var cancellations = 0
    private(set) var maximumConcurrentSaves = 0

    func accountStatus() async throws -> CKAccountStatus {
        try await withCheckedThrowingContinuation { accountWaiter = $0 }
    }

    func save(_ snapshot: ThrottleMirrorSnapshot) async throws {
        saved.append(snapshot)
        savedAccountLabels.append(accountLabel)
        try await withCheckedThrowingContinuation {
            saveWaiters.append($0)
            maximumConcurrentSaves = max(maximumConcurrentSaves, saveWaiters.count)
        }
    }

    func cancel() { cancellations += 1 }

    func resolveAccount(_ status: CKAccountStatus) throws {
        let waiter = try XCTUnwrap(accountWaiter)
        accountWaiter = nil
        waiter.resume(returning: status)
    }

    func resolveSave(error: Error? = nil) throws {
        let waiter = try XCTUnwrap(saveWaiters.first)
        saveWaiters.removeFirst()
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }
}

@MainActor
private final class CloudPublisherDelayFake {
    var waiter: CheckedContinuation<Void, Error>?
    private(set) var intervals: [TimeInterval] = []

    func sleep(_ interval: TimeInterval) async throws {
        intervals.append(interval)
        try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func resolve() throws {
        let continuation = try XCTUnwrap(waiter)
        waiter = nil
        continuation.resume()
    }
}
