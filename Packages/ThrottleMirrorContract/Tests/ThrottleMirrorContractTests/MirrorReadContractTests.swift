import Foundation
import ThrottleMirrorContract
import XCTest

final class MirrorReadContractTests: XCTestCase {
    func testReadProjectionPreservesTheLegacyDisplayJSON() throws {
        let data = try fixture()
        let read = try MirrorReadSnapshot.decoded(from: data)
        XCTAssertEqual(try object(read.encoded()) as NSDictionary, try object(data) as NSDictionary)
        XCTAssertEqual(read.bindingWindow.utilization, 50)
        XCTAssertEqual(read.tabs.first?.stateKind, .waiting)
        XCTAssertNil(read.tabs.first?.eur)
        XCTAssertNil(read.tabs.first?.tokens)
    }

    func testDecodingAnEnvelopeCannotRetainOrReencodeProvisioning() throws {
        var json = try object(fixture())
        let fields = ["peerPairingSecret", "peerFallbackHost", "edgeHost", "edgePort", "edgeToken"]
        for field in fields { json[field] = "SYNTHETIC-PROVISIONING-CANARY" }
        let read = try MirrorReadSnapshot.decoded(from: JSONSerialization.data(withJSONObject: json))
        let encoded = try read.encoded()
        let result = try object(encoded)
        for field in fields { XCTAssertNil(result[field], field) }
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("SYNTHETIC-PROVISIONING-CANARY"))
    }

    func testLegacyAndFutureVersionsKeepUnknownSessionStates() throws {
        for version in [1, 99] {
            var json = try object(fixture())
            json["schemaVersion"] = version
            var tabs = try XCTUnwrap(json["tabs"] as? [[String: Any]])
            tabs[0]["state"] = "future-state"
            json["tabs"] = tabs
            let read = try MirrorReadSnapshot.decoded(from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(read.schemaVersion, version)
            XCTAssertEqual(read.tabs.first?.state, "future-state")
            XCTAssertNil(read.tabs.first?.stateKind)
            XCTAssertEqual(try MirrorReadSnapshot.decoded(from: read.encoded()), read)
        }
    }

    func testMissingOrMalformedRequiredDisplayDataIsRejected() throws {
        var missing = try object(fixture())
        missing.removeValue(forKey: "weeklyTokens")
        XCTAssertThrowsError(try MirrorReadSnapshot.decoded(from: JSONSerialization.data(withJSONObject: missing)))
        var malformed = try object(fixture())
        malformed["publishedAt"] = "not-a-date"
        XCTAssertThrowsError(try MirrorReadSnapshot.decoded(from: JSONSerialization.data(withJSONObject: malformed)))
    }

    func testReadContractEncodesOnlyTheKnownDisplayKeys() throws {
        let read = try MirrorReadSnapshot.decoded(from: fixture())
        XCTAssertEqual(Set(try object(read.encoded()).keys), [
            "schemaVersion", "publishedAt", "deviceName", "fiveHour", "sevenDay", "sevenDaySonnet",
            "weeklyTokens", "weeklyCostEUR", "savedTokensThisWeek", "sessionCount", "tabs"
        ])
    }

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "read-snapshot", withExtension: "json", subdirectory: "Fixtures"
        ))
        return try Data(contentsOf: url)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
