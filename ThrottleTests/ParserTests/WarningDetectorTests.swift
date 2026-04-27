import XCTest
@testable import Throttle

final class WarningDetectorTests: XCTestCase {
    func test_detects90PercentWeeklyWarning() throws {
        let line = #"{"type":"system","message":{"role":"system","content":"You've used 90% of your weekly Claude Code allowance. Resets Tue 16:00."}}"#
        let warning = try WarningDetector.detect(inLine: line)
        XCTAssertNotNil(warning)
        XCTAssertEqual(warning?.percent, 90)
        XCTAssertEqual(warning?.window, .weekly)
    }

    func test_detects80PercentSessionWarning() throws {
        let line = #"{"type":"system","message":{"role":"system","content":"You've used 80% of your current 5-hour session limit."}}"#
        let warning = try WarningDetector.detect(inLine: line)
        XCTAssertNotNil(warning)
        XCTAssertEqual(warning?.percent, 80)
        XCTAssertEqual(warning?.window, .session)
    }

    func test_returnsNilForRegularMessage() throws {
        let line = #"{"type":"assistant","message":{"role":"assistant","content":"hi","usage":{"input_tokens":10,"output_tokens":5}}}"#
        XCTAssertNil(try WarningDetector.detect(inLine: line))
    }

    func test_returnsNilForMalformedJson() throws {
        XCTAssertNil(try WarningDetector.detect(inLine: "not json"))
    }
}
