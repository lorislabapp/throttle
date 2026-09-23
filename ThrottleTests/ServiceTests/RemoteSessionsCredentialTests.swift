@testable import Throttle
import XCTest

/// Explicit constructor dependencies bypass shared, Keychain and UserDefaults.
@MainActor
final class RemoteSessionsCredentialTests: XCTestCase {
    func testFailedReplacementKeepsPreviousTokenAndShowsError() {
        var writes: [String] = []
        var legacyRemoved = false
        let service = RemoteSessionsService(initialHost: "", initialPort: 8787,
            savedToken: "synthetic-old", legacyToken: nil,
            persistToken: { value, account in
                writes.append(account)
                XCTAssertEqual(value, "synthetic-new")
                return false
            }, removeLegacy: { legacyRemoved = true })
        service.token = "synthetic-new"
        XCTAssertEqual(service.token, "synthetic-old")
        XCTAssertNotNil(service.tokenPersistenceError)
        XCTAssertEqual(writes, ["edgeAgentToken"])
        XCTAssertFalse(legacyRemoved)
        XCTAssertFalse(service.polling)
    }

    func testFailedMigrationRetainsLegacyThenSuccessfulSaveClearsErrorAndLegacy() {
        var canPersist = false
        var legacyRemoved = false
        let service = RemoteSessionsService(initialHost: "", initialPort: 8787,
            savedToken: nil, legacyToken: "synthetic-legacy",
            persistToken: { _, _ in canPersist }, removeLegacy: { legacyRemoved = true })
        XCTAssertEqual(service.token, "synthetic-legacy")
        XCTAssertNotNil(service.tokenPersistenceError)
        XCTAssertFalse(legacyRemoved)
        canPersist = true
        service.token = "synthetic-replacement"
        XCTAssertEqual(service.token, "synthetic-replacement")
        XCTAssertNil(service.tokenPersistenceError)
        XCTAssertTrue(legacyRemoved)
    }

    func testSuccessfulLegacyMigrationDeletesOnlyAfterPersistence() {
        var events: [String] = []
        let service = RemoteSessionsService(initialHost: "", initialPort: 8787,
            savedToken: nil, legacyToken: "synthetic-legacy",
            persistToken: { _, _ in events.append("persist"); return true },
            removeLegacy: { events.append("remove") })
        XCTAssertEqual(events, ["persist", "remove"])
        XCTAssertEqual(service.token, "synthetic-legacy")
        XCTAssertNil(service.tokenPersistenceError)
    }

    func testStoredTokenWinsOverLegacyWithoutWritingDuringConstruction() {
        var writeCount = 0
        let service = RemoteSessionsService(initialHost: "", initialPort: 8787,
            savedToken: "synthetic-saved", legacyToken: "synthetic-legacy",
            persistToken: { _, _ in writeCount += 1; return true }, removeLegacy: {})
        XCTAssertEqual(service.token, "synthetic-saved")
        XCTAssertEqual(writeCount, 0)
    }
    func testUnreadableKeychainNeverAutomaticallyMigratesOrRemovesLegacy() {
        var writes = 0
        var removals = 0
        let service = RemoteSessionsService(initialHost: "", initialPort: 8787,
            savedToken: nil, legacyToken: "synthetic-legacy", credentialUnavailable: true,
            persistToken: { _, _ in writes += 1; return true }, removeLegacy: { removals += 1 })
        XCTAssertEqual(service.token, "")
        XCTAssertFalse(service.isConfigured)
        XCTAssertNotNil(service.tokenPersistenceError)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(removals, 0)
    }
}
