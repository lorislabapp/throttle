@testable import Throttle
import XCTest

final class ReviewedPasteServiceTests: XCTestCase {
    func testReviewThresholds() {
        XCTAssertFalse(ReviewedPasteService.requiresReview("one line"))
        XCTAssertFalse(ReviewedPasteService.requiresReview("one\ntwo\nthree"))
        XCTAssertTrue(ReviewedPasteService.requiresReview("one\ntwo\nthree\nfour"))
        XCTAssertTrue(ReviewedPasteService.requiresReview(String(repeating: "a", count: 4_097)))
    }

    func testChallengeBindsExactBytesAndExpires() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let challenge = try ReviewedPasteService.prepare("first\nsecond\nthird\nfourth", now: now)
        XCTAssertEqual(challenge.lineCount, 4)
        XCTAssertTrue(ReviewedPasteService.validates(challenge, text: "first\nsecond\nthird\nfourth", now: now))
        XCTAssertFalse(ReviewedPasteService.validates(challenge, text: "changed", now: now))
        XCTAssertFalse(ReviewedPasteService.validates(
            challenge, text: "first\nsecond\nthird\nfourth", now: now.addingTimeInterval(31)
        ))
    }

    func testRejectsEscapeNulAndOversizePayloads() {
        XCTAssertThrowsError(try ReviewedPasteService.prepare("safe\u{1b}[31m"))
        XCTAssertThrowsError(try ReviewedPasteService.prepare("safe\0unsafe"))
        XCTAssertThrowsError(try ReviewedPasteService.prepare(
            String(repeating: "x", count: ReviewedPasteService.maximumBytes + 1)
        ))
    }

    func testAcceptsReviewedBuildLogLargerThanLegacy64KiBLimit() throws {
        let log = String(repeating: "compile warning: sample\n", count: 4_000)
        XCTAssertGreaterThan(log.utf8.count, 64 * 1024)
        XCTAssertLessThan(log.utf8.count, ReviewedPasteService.maximumBytes)
        XCTAssertNoThrow(try ReviewedPasteService.prepare(log))
    }
}
