import CloudKit
import Foundation
@testable import Throttle
import ThrottleShared
import XCTest

@MainActor
final class CloudKitSubscriberPrivacyTests: XCTestCase {
    func testBootstrapHidesUnverifiedCacheAndScrubsDifferentOwnerBeforeFetch() async throws {
        let defaults = try MirrorPrivacyFixture.defaults()
        try MirrorPrivacyFixture.seedCache(defaults)
        let store = MirrorPrivacyFixture.store(defaults)
        XCTAssertNil(store.latest)
        let backend = MirrorCloudFake()
        backend.identity = "account-B"
        backend.snapshotHandler = {
            XCTAssertNil(store.latest)
            XCTAssertNil(defaults.data(forKey: MirrorStore.historyKey))
            return nil
        }
        let subscriber = CloudKitSubscriber(backend: backend, defaults: defaults, mirror: store,
                                            pair: { _ in XCTFail("No snapshot was returned") }, notifications: nil)
        await subscriber.bootstrap()
        XCTAssertEqual(defaults.string(forKey: CloudKitSubscriber.userRecordKey), "account-B")
        XCTAssertNil(store.latest)
    }

    func testSameProvenOwnerRetainsCacheWhenNoNewSnapshotExists() async throws {
        let defaults = try MirrorPrivacyFixture.defaults()
        try MirrorPrivacyFixture.seedCache(defaults)
        let store = MirrorPrivacyFixture.store(defaults)
        let subscriber = CloudKitSubscriber(backend: MirrorCloudFake(), defaults: defaults, mirror: store,
                                            pair: { _ in }, notifications: nil)
        let changed = await subscriber.fetchLatest()
        XCTAssertFalse(changed)
        XCTAssertEqual(store.latest, MirrorPrivacyFixture.snapshot())
        XCTAssertEqual(store.history.count, 1)
    }

    func testUnownedLegacyCacheIsNotAssignedToFirstAccount() async throws {
        let defaults = try MirrorPrivacyFixture.defaults()
        try MirrorPrivacyFixture.seedCache(defaults, owner: nil)
        let store = MirrorPrivacyFixture.store(defaults)
        let subscriber = CloudKitSubscriber(backend: MirrorCloudFake(), defaults: defaults, mirror: store,
                                            pair: { _ in }, notifications: nil)
        _ = await subscriber.fetchLatest()
        XCTAssertNil(store.latest)
        XCTAssertNil(defaults.data(forKey: MirrorStore.historyKey))
    }

    func testDelayedAccountAResponseCannotRepopulateAccountB() async throws {
        let defaults = try MirrorPrivacyFixture.defaults()
        let store = MirrorPrivacyFixture.store(defaults)
        let backend = MirrorCloudFake()
        let gate = MirrorTestGate<ThrottleMirrorSnapshot?>()
        backend.snapshotHandler = { await gate.value() }
        var paired: [ThrottleMirrorSnapshot] = []
        let subscriber = CloudKitSubscriber(backend: backend, defaults: defaults, mirror: store,
                                            pair: { paired.append($0) }, notifications: nil)
        let old = Task { await subscriber.fetchLatest() }
        await gate.waitUntilEntered()
        subscriber.accountDidChange()
        backend.identity = "account-B"
        backend.snapshotHandler = nil
        backend.snapshot = MirrorPrivacyFixture.snapshot(2)
        let current = await subscriber.fetchLatest()
        XCTAssertTrue(current)
        await gate.resume(MirrorPrivacyFixture.snapshot(3))
        let acceptedOld = await old.value
        XCTAssertFalse(acceptedOld)
        XCTAssertEqual(store.latest, backend.snapshot)
        XCTAssertEqual(paired, [MirrorPrivacyFixture.snapshot(2)])
        XCTAssertEqual(defaults.string(forKey: CloudKitSubscriber.userRecordKey), "account-B")
        store.scrub()
    }

    func testIdentityChangedWithoutNotificationRejectsFetchedRecordAndPairing() async throws {
        let defaults = try MirrorPrivacyFixture.defaults()
        let store = MirrorPrivacyFixture.store(defaults)
        let backend = MirrorCloudFake()
        backend.snapshotHandler = {
            backend.identity = "account-B"
            return MirrorPrivacyFixture.snapshot()
        }
        let subscriber = CloudKitSubscriber(backend: backend, defaults: defaults, mirror: store,
                                            pair: { _ in XCTFail("Stale pairing") }, notifications: nil)
        let accepted = await subscriber.fetchLatest()
        XCTAssertFalse(accepted)
        XCTAssertNil(store.latest)
        XCTAssertNil(defaults.string(forKey: CloudKitSubscriber.userRecordKey))
    }

    func testIdentityFailureAfterRecordDoesNotRestorePreviousAuthorization() async throws {
        let defaults = try MirrorPrivacyFixture.defaults()
        try MirrorPrivacyFixture.seedCache(defaults)
        let store = MirrorPrivacyFixture.store(defaults)
        let backend = MirrorCloudFake()
        backend.snapshot = MirrorPrivacyFixture.snapshot(2)
        backend.identityHandler = {
            if backend.identityCalls > 1 { throw MirrorCloudError.missingIdentity }
            return "account-A"
        }
        let subscriber = CloudKitSubscriber(backend: backend, defaults: defaults, mirror: store,
                                            pair: { _ in XCTFail("Identity lookup failed") }, notifications: nil)
        let accepted = await subscriber.fetchLatest()
        XCTAssertFalse(accepted)
        XCTAssertNil(store.latest)
        XCTAssertNil(defaults.string(forKey: CloudKitSubscriber.userRecordKey))
        XCTAssertNotEqual(subscriber.account, .available)
    }

    func testSignOutImmediatelyRevokesMirrorPeerAndErrors() async throws {
        let defaults = try MirrorPrivacyFixture.defaults()
        var scrubCount = 0
        let store = MirrorPrivacyFixture.store(defaults) { scrubCount += 1 }
        store.ingest(MirrorPrivacyFixture.snapshot())
        store.lastError = "Old account error"
        let backend = MirrorCloudFake()
        backend.status = .noAccount
        let subscriber = CloudKitSubscriber(backend: backend, defaults: defaults, mirror: store,
                                            pair: { _ in }, notifications: nil)
        _ = await subscriber.fetchLatest()
        XCTAssertEqual(subscriber.account, .signedOut)
        XCTAssertEqual(backend.snapshotCalls, 0)
        XCTAssertEqual(scrubCount, 1)
        XCTAssertNil(store.latest)
        XCTAssertNil(store.lastError)
    }

    func testLateSubscriptionCannotRestorePushAuthorizationAfterAccountChange() async throws {
        let defaults = try MirrorPrivacyFixture.defaults()
        let store = MirrorPrivacyFixture.store(defaults)
        let backend = MirrorCloudFake()
        let gate = MirrorTestGate<Bool>()
        backend.subscriptionHandler = { _ = await gate.value() }
        let subscriber = CloudKitSubscriber(backend: backend, defaults: defaults, mirror: store,
                                            pair: { _ in }, notifications: nil)
        let bootstrap = Task { await subscriber.bootstrap() }
        await gate.waitUntilEntered()
        subscriber.accountDidChange()
        await gate.resume(true)
        await bootstrap.value
        XCTAssertFalse(subscriber.pushAvailable)
        XCTAssertEqual(subscriber.account, .unknown)
        XCTAssertNil(defaults.string(forKey: CloudKitSubscriber.userRecordKey))
    }

    func testLateIdentityCannotBindItsCacheToTheNextAccount() async throws {
        let defaults = try MirrorPrivacyFixture.defaults()
        let store = MirrorPrivacyFixture.store(defaults)
        let backend = MirrorCloudFake()
        let gate = MirrorTestGate<String>()
        backend.identityHandler = { await gate.value() }
        let subscriber = CloudKitSubscriber(backend: backend, defaults: defaults, mirror: store,
                                            pair: { _ in }, notifications: nil)
        let old = Task { await subscriber.fetchLatest() }
        await gate.waitUntilEntered()
        subscriber.accountDidChange()
        backend.identityHandler = nil
        backend.identity = "account-B"
        backend.snapshot = MirrorPrivacyFixture.snapshot(2)
        _ = await subscriber.fetchLatest()
        await gate.resume("account-A")
        let accepted = await old.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(store.latest, backend.snapshot)
        XCTAssertEqual(defaults.string(forKey: CloudKitSubscriber.userRecordKey), "account-B")
        store.scrub()
    }

    func testLateFailureCannotOverwriteTheNewAccountState() async throws {
        let defaults = try MirrorPrivacyFixture.defaults()
        let store = MirrorPrivacyFixture.store(defaults)
        let backend = MirrorCloudFake()
        let gate = MirrorTestGate<Bool>()
        backend.snapshotHandler = {
            _ = await gate.value()
            throw MirrorCloudError.missingIdentity
        }
        let subscriber = CloudKitSubscriber(backend: backend, defaults: defaults, mirror: store,
                                            pair: { _ in }, notifications: nil)
        let old = Task { await subscriber.fetchLatest() }
        await gate.waitUntilEntered()
        subscriber.accountDidChange()
        backend.identity = "account-B"
        backend.snapshotHandler = nil
        backend.snapshot = MirrorPrivacyFixture.snapshot(2)
        _ = await subscriber.fetchLatest()
        await gate.resume(true)
        _ = await old.value
        XCTAssertNil(store.lastError)
        XCTAssertEqual(subscriber.account, .available)
        XCTAssertEqual(store.latest, backend.snapshot)
        store.scrub()
    }

    func testAccountNotificationScrubsBeforeItsAsynchronousRefreshStarts() async throws {
        let defaults = try MirrorPrivacyFixture.defaults()
        let store = MirrorPrivacyFixture.store(defaults)
        let backend = MirrorCloudFake()
        backend.snapshot = MirrorPrivacyFixture.snapshot()
        let center = NotificationCenter()
        let subscriber = CloudKitSubscriber(backend: backend, defaults: defaults, mirror: store,
                                            pair: { _ in }, notifications: center)
        await subscriber.bootstrap()
        XCTAssertNotNil(store.latest)
        backend.status = .noAccount
        center.post(name: .CKAccountChanged, object: nil)
        XCTAssertNil(store.latest)
        XCTAssertFalse(subscriber.pushAvailable)
        XCTAssertNil(defaults.string(forKey: CloudKitSubscriber.userRecordKey))
        _ = await subscriber.fetchLatest()
    }

    func testDifferentOwnerCannotInheritPreviousPushSubscription() async throws {
        let defaults = try MirrorPrivacyFixture.defaults()
        let store = MirrorPrivacyFixture.store(defaults)
        let backend = MirrorCloudFake()
        let subscriber = CloudKitSubscriber(backend: backend, defaults: defaults, mirror: store,
                                            pair: { _ in }, notifications: nil)
        await subscriber.bootstrap()
        XCTAssertTrue(subscriber.pushAvailable)
        backend.identity = "account-B"
        _ = await subscriber.fetchLatest()
        XCTAssertFalse(subscriber.pushAvailable)
        XCTAssertEqual(defaults.string(forKey: CloudKitSubscriber.userRecordKey), "account-B")
    }
}
