import CloudKit
@testable import ThrottleShared
import XCTest

final class MirrorEnvelopeCompatibilityTests: XCTestCase {
    func testEnvelopePreservesAllLegacyJSONFields() throws {
        let data = try fixture()
        let snapshot = try ThrottleMirrorSnapshot.decoded(from: data)
        XCTAssertEqual(try object(snapshot.encoded()) as NSDictionary, try object(data) as NSDictionary)
        XCTAssertEqual(snapshot.peerPairingSecret, "SYNTHETIC-PAIRING-NOT-A-SECRET")
        XCTAssertEqual(snapshot.edgeToken, "SYNTHETIC-EDGE-NOT-A-SECRET")
        XCTAssertEqual(snapshot.provisioning.edgePort, 9876)
        XCTAssertEqual(snapshot.readSnapshot.weeklyTokens, 1234)
    }

    func testReadProjectionRemovesEveryProvisioningField() throws {
        let snapshot = try ThrottleMirrorSnapshot.decoded(from: fixture())
        let projected = try object(snapshot.readSnapshot.encoded())
        for field in ["peerPairingSecret", "peerFallbackHost", "edgeHost", "edgePort", "edgeToken"] {
            XCTAssertNil(projected[field], field)
        }
        let readOnlyEnvelope = ThrottleMirrorSnapshot(readSnapshot: snapshot.readSnapshot)
        XCTAssertEqual(try object(readOnlyEnvelope.encoded()) as NSDictionary, projected as NSDictionary)
        XCTAssertNil(readOnlyEnvelope.peerPairingSecret)
    }

    func testDiskProjectionKeepsLegacyMetadataButDropsBothCredentials() throws {
        let snapshot = try ThrottleMirrorSnapshot.decoded(from: fixture())
        let stripped = snapshot.withoutSecrets
        var expected = try object(fixture())
        expected.removeValue(forKey: "peerPairingSecret")
        expected.removeValue(forKey: "edgeToken")
        XCTAssertEqual(try object(stripped.encoded()) as NSDictionary, expected as NSDictionary)
        XCTAssertEqual(stripped.withoutSecrets, stripped)
        XCTAssertEqual(stripped.readSnapshot, snapshot.readSnapshot)
    }

    func testLegacyPayloadWithoutProvisioningAndWithNullsStillDecodes() throws {
        for nulls in [false, true] {
            var json = try object(fixture())
            json["schemaVersion"] = 1
            for field in ["peerPairingSecret", "peerFallbackHost", "edgeHost", "edgePort", "edgeToken"] {
                if nulls { json[field] = NSNull() } else { json.removeValue(forKey: field) }
            }
            let snapshot = try ThrottleMirrorSnapshot.decoded(from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(snapshot.provisioning, MirrorProvisioning())
            XCTAssertEqual(snapshot.schemaVersion, 1)
        }
    }

    func testCloudKitKeepsProvisioningOnlyInsideEncryptedPayload() throws {
        let snapshot = try ThrottleMirrorSnapshot.decoded(from: fixture())
        let record = try CloudKitRecordMapping.record(from: snapshot)
        XCTAssertNil(record[CloudKitSchema.Field.payload])
        XCTAssertNil(record["peerPairingSecret"])
        XCTAssertNil(record["edgeToken"])
        let payload = try XCTUnwrap(record.encryptedValues[CloudKitSchema.Field.payload] as? Data)
        XCTAssertEqual(try object(payload) as NSDictionary, try object(fixture()) as NSDictionary)
        XCTAssertEqual(try CloudKitRecordMapping.snapshot(from: record), snapshot)
    }

    func testOutboundScrubbingStillAppliesBeforeReadProjection() throws {
        var json = try object(fixture())
        json["deviceName"] = "sk-ant-api03-SYNTHETICcanary0123456789"
        let snapshot = try ThrottleMirrorSnapshot.decoded(from: JSONSerialization.data(withJSONObject: json))
        let read = snapshot.scrubbedForPublication().readSnapshot
        XCTAssertEqual(read.deviceName, "[redacted:anthropic-key]")
        XCTAssertEqual(read.weeklyTokens, snapshot.weeklyTokens)
    }

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "pre-extraction-mirror", withExtension: "json", subdirectory: "Fixtures"
        ))
        return try Data(contentsOf: url)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
