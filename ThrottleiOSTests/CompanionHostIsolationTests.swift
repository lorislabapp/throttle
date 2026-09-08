import Foundation
@testable import Throttle
import ThrottleShared
import XCTest

@MainActor
final class CompanionHostIsolationTests: XCTestCase {
    func testHostedTestsUseTheirOwnDefaultsAndCannotStartTheSharedPeer() {
        XCTAssertTrue(CompanionRuntime.isTesting)
        XCTAssertTrue(CompanionRuntime.defaultsSuiteName.hasPrefix("Throttle-Isolated-Test-Host-"))
        XCTAssertNotEqual(CompanionRuntime.defaultsSuiteName, MirrorStorage.appGroupID)
        PeerClient.shared.syncPairing(from: MirrorPrivacyFixture.snapshot(
            secret: Data(repeating: 1, count: 32).base64EncodedString()))
        XCTAssertFalse(PeerClient.shared.hasLink)
    }

    func testProductionCloudBackendRejectsAllEntrypointsBeforeOpeningContainer() async {
        let backend = SystemMirrorCloudBackend()
        let operations: [() async throws -> Void] = [
            { _ = try await backend.accountStatus() },
            { _ = try await backend.userRecordName() },
            { _ = try await backend.latestSnapshot() },
            { try await backend.ensureSubscription() }
        ]
        for operation in operations {
            do {
                try await operation()
                XCTFail("Production CloudKit must remain unavailable in an XCTest host")
            } catch MirrorCloudError.systemServiceDisabledInTestHost {
                // The backend rejects before constructing CKContainer.
            } catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testDefaultStoreUsesOnlyTestDefaultsAndNotificationsStayDisabled() async throws {
        let store = MirrorStore()
        store.ingest(MirrorPrivacyFixture.snapshot())
        XCTAssertNotNil(CompanionRuntime.defaults.data(forKey: MirrorStorage.latestSnapshotKey))
        let allowed = await ThresholdNotifier.shared.requestAuthorization()
        XCTAssertFalse(allowed)
        store.scrub()
        XCTAssertNil(CompanionRuntime.defaults.data(forKey: MirrorStorage.latestSnapshotKey))
        XCTAssertNil(CompanionRuntime.defaults.data(forKey: MirrorStore.historyKey))
    }
}
