import Foundation
@testable import Throttle
import ThrottleShared
import XCTest

@MainActor
final class MirrorStorePrivacyTests: XCTestCase {
    func testEncodingAlreadyInFlightCannotWriteAfterScrub() async throws {
        let defaults = try MirrorPrivacyFixture.defaults()
        let gate = MirrorTestGate<Data?>()
        var scrubbedSurfaces = false
        let store = MirrorStore(defaults: defaults, historyEncoder: { _ in await gate.value() },
                                flushDelayNanoseconds: 0, reloadWidgets: {}, didIngest: { _ in },
                                didScrub: { scrubbedSurfaces = true })
        store.ingest(MirrorPrivacyFixture.snapshot())
        let flush = try XCTUnwrap(store.historyFlush)
        await gate.waitUntilEntered()
        store.scrub()
        await gate.resume(try JSONEncoder.iso.encode([MirrorPrivacyFixture.snapshot()]))
        await flush.value
        XCTAssertTrue(scrubbedSurfaces)
        XCTAssertNil(store.latest)
        XCTAssertNil(defaults.data(forKey: MirrorStorage.latestSnapshotKey))
        XCTAssertNil(defaults.data(forKey: MirrorStore.historyKey))
        XCTAssertNil(MirrorWidgetPublication.read(from: defaults))
    }

    func testSupersededEncodingCannotOverwriteNewerHistoryAndSecretsNeverPersist() async throws {
        let defaults = try MirrorPrivacyFixture.defaults()
        let gate = MirrorTestGate<Data?>()
        let store = MirrorStore(defaults: defaults, historyEncoder: { snapshots in
            XCTAssertTrue(snapshots.allSatisfy { $0.peerPairingSecret == nil })
            if snapshots.count == 1 { return await gate.value() }
            return try? JSONEncoder.iso.encode(snapshots)
        }, flushDelayNanoseconds: 0, reloadWidgets: {}, didIngest: { _ in }, didScrub: {})
        store.ingest(MirrorPrivacyFixture.snapshot(secret: Data(repeating: 1, count: 32).base64EncodedString()))
        let oldFlush = try XCTUnwrap(store.historyFlush)
        await gate.waitUntilEntered()
        store.ingest(MirrorPrivacyFixture.snapshot(2))
        await store.historyFlush?.value
        let current = defaults.data(forKey: MirrorStore.historyKey)
        await gate.resume(Data("old-encoding".utf8))
        await oldFlush.value
        XCTAssertEqual(defaults.data(forKey: MirrorStore.historyKey), current)
        let data = try XCTUnwrap(current)
        XCTAssertEqual(try JSONDecoder.iso.decode([ThrottleMirrorSnapshot].self, from: data).count, 2)
        let latestData = try XCTUnwrap(defaults.data(forKey: MirrorStorage.latestSnapshotKey))
        XCTAssertNil(try ThrottleMirrorSnapshot.decoded(from: latestData).peerPairingSecret)
        store.scrub()
    }

    func testWidgetPublicationIsRevokedUntilTheCachedOwnerIsProven() async throws {
        let defaults = try MirrorPrivacyFixture.defaults()
        try MirrorPrivacyFixture.seedCache(defaults)
        defaults.set(try MirrorPrivacyFixture.snapshot().encoded(), forKey: MirrorWidgetPublication.snapshotKey)
        XCTAssertNotNil(MirrorWidgetPublication.read(from: defaults))
        let store = MirrorPrivacyFixture.store(defaults)
        XCTAssertNil(MirrorWidgetPublication.read(from: defaults))
        let subscriber = CloudKitSubscriber(backend: MirrorCloudFake(), defaults: defaults, mirror: store,
                                            pair: { _ in }, notifications: nil)
        _ = await subscriber.fetchLatest()
        XCTAssertEqual(MirrorWidgetPublication.read(from: defaults), MirrorPrivacyFixture.snapshot())
        subscriber.accountDidChange()
        XCTAssertNil(MirrorWidgetPublication.read(from: defaults))
        XCTAssertNil(defaults.data(forKey: MirrorStorage.latestSnapshotKey))
    }

    func testWidgetNeverFallsBackToLegacyCacheOrPublishesAnotherOwnersHistory() async throws {
        let defaults = try MirrorPrivacyFixture.defaults()
        try MirrorPrivacyFixture.seedCache(defaults)
        XCTAssertNil(MirrorWidgetPublication.read(from: defaults))
        let store = MirrorPrivacyFixture.store(defaults)
        let backend = MirrorCloudFake()
        backend.identity = "account-B"
        let subscriber = CloudKitSubscriber(backend: backend, defaults: defaults, mirror: store,
                                            pair: { _ in }, notifications: nil)
        _ = await subscriber.fetchLatest()
        XCTAssertNil(MirrorWidgetPublication.read(from: defaults))
        defaults.set(Data("malformed".utf8), forKey: MirrorWidgetPublication.snapshotKey)
        XCTAssertNil(MirrorWidgetPublication.read(from: defaults))
    }
}
