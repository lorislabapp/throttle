import XCTest
@testable import Throttle

final class ExactSnapshotTests: XCTestCase {
    func test_decodesCanonicalResponse() throws {
        let json = #"""
        {
          "five_hour":         { "utilization": 25, "resets_at": "2026-04-28T19:00:00.742770+00:00" },
          "seven_day":         { "utilization":  3, "resets_at": "2026-05-05T14:00:00.742791+00:00" },
          "seven_day_sonnet":  { "utilization":  0, "resets_at": null }
        }
        """#.data(using: .utf8)!

        let snap = try ExactSnapshot.decode(from: json)

        XCTAssertEqual(snap.fiveHour.utilization, 25)
        XCTAssertNotNil(snap.fiveHour.resetsAt)
        XCTAssertEqual(snap.sevenDay.utilization, 3)
        XCTAssertEqual(snap.sevenDaySonnet.utilization, 0)
        XCTAssertNil(snap.sevenDaySonnet.resetsAt)
    }

    func test_isFresh_withinTenMinutes_returnsTrue() throws {
        let snap = ExactSnapshot(
            fiveHour: .init(utilization: 0, resetsAt: nil),
            sevenDay: .init(utilization: 0, resetsAt: nil),
            sevenDaySonnet: .init(utilization: 0, resetsAt: nil),
            fetchedAt: Date()
        )
        XCTAssertTrue(snap.isFresh())
    }

    func test_isFresh_olderThanTenMinutes_returnsFalse() throws {
        let snap = ExactSnapshot(
            fiveHour: .init(utilization: 0, resetsAt: nil),
            sevenDay: .init(utilization: 0, resetsAt: nil),
            sevenDaySonnet: .init(utilization: 0, resetsAt: nil),
            fetchedAt: Date().addingTimeInterval(-15 * 60)
        )
        XCTAssertFalse(snap.isFresh())
    }
}
