import XCTest
import CloudKit
@testable import ThrottleShared

final class CloudKitRecordMappingTests: XCTestCase {

    private func sample() -> ThrottleMirrorSnapshot {
        ThrottleMirrorSnapshot(
            publishedAt: Date(timeIntervalSince1970: 1_770_000_000),
            deviceName: "Kevin's Mac",
            fiveHour: .init(utilization: 42, resetsAt: Date(timeIntervalSince1970: 1_770_003_600)),
            sevenDay: .init(utilization: 7, resetsAt: nil),
            sevenDaySonnet: .init(utilization: 0, resetsAt: nil),
            weeklyTokens: 1_234_567,
            weeklyCostEUR: 12.34,
            savedTokensThisWeek: 89_000,
            sessionCount: 3,
            tabs: [
                .init(id: "s1", projectName: "Throttle", state: "working", model: "opus",
                      eur: 1.1, tokens: 5000, isLive: true, needsInput: false, rateLimitedUntil: nil),
                .init(id: "s2", projectName: "Lumen", state: "waiting", model: "sonnet",
                      eur: 0.2, tokens: 900, isLive: true, needsInput: true, rateLimitedUntil: nil)
            ])
    }

    func test_jsonRoundTrip_isLossless() throws {
        let snap = sample()
        let back = try ThrottleMirrorSnapshot.decoded(from: snap.encoded())
        XCTAssertEqual(snap, back)
    }

    func test_recordRoundTrip_isLossless() throws {
        let snap = sample()
        let record = try CloudKitRecordMapping.record(from: snap)
        XCTAssertEqual(record.recordType, CloudKitSchema.recordType)
        XCTAssertEqual(record.recordID.recordName, "current-default")
        XCTAssertEqual(record[CloudKitSchema.Field.schemaVersion] as? Int, ThrottleMirrorSnapshot.currentSchemaVersion)
        let back = try CloudKitRecordMapping.snapshot(from: record)
        XCTAssertEqual(snap, back)
        XCTAssertEqual(back.tabs.count, 2)
        XCTAssertEqual(back.bindingWindow.utilization, 42)
    }

    func test_missingPayload_throws() {
        let empty = CKRecord(recordType: CloudKitSchema.recordType)
        XCTAssertThrowsError(try CloudKitRecordMapping.snapshot(from: empty)) {
            XCTAssertEqual($0 as? CloudKitRecordMapping.MappingError, .missingPayload)
        }
    }

    func test_bindingWindow_picksWorst() {
        let snap = sample()
        XCTAssertEqual(snap.bindingWindow.utilization, 42) // 5h=42 > 7d=7 > sonnet=0
    }
}
