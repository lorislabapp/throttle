import XCTest
@testable import Throttle

/// Locks the test-runner summary regexes — the fragile part of the eval-ROI signal.
/// A false positive here would pollute the "green runs" count; a miss would undercount.
final class TestOutcomeDetectorTests: XCTestCase {

    func test_pytest_passOnly() {
        let o = TestOutcomeDetector.detect(in: "======== 12 passed in 3.41s ========")
        XCTAssertEqual(o?.framework, "pytest")
        XCTAssertEqual(o?.passed, 12); XCTAssertEqual(o?.failed, 0)
        XCTAssertTrue(o?.green == true)
    }

    func test_pytest_withFailures() {
        let o = TestOutcomeDetector.detect(in: "===== 10 passed, 2 failed, 1 skipped in 5.0s =====")
        XCTAssertEqual(o?.passed, 10); XCTAssertEqual(o?.failed, 2)
        XCTAssertFalse(o?.green == true)
    }

    func test_cargo() {
        let o = TestOutcomeDetector.detect(in: "test result: FAILED. 40 passed; 3 failed; 0 ignored; 0 measured")
        XCTAssertEqual(o?.framework, "cargo")
        XCTAssertEqual(o?.passed, 40); XCTAssertEqual(o?.failed, 3)
    }

    func test_jest_failedFirstOrder() {
        let o = TestOutcomeDetector.detect(in: "Tests:       2 failed, 10 passed, 12 total")
        XCTAssertEqual(o?.framework, "jest")
        XCTAssertEqual(o?.passed, 10); XCTAssertEqual(o?.failed, 2)
    }

    func test_jest_passOnly() {
        let o = TestOutcomeDetector.detect(in: "Tests:       12 passed, 12 total")
        XCTAssertEqual(o?.passed, 12); XCTAssertEqual(o?.failed, 0)
    }

    func test_swift() {
        let o = TestOutcomeDetector.detect(in: "Executed 30 tests, with 4 failures (0 unexpected) in 1.2 seconds")
        XCTAssertEqual(o?.framework, "swift")
        XCTAssertEqual(o?.passed, 26); XCTAssertEqual(o?.failed, 4)
    }

    func test_go_ok() {
        let o = TestOutcomeDetector.detect(in: "ok  \tgithub.com/x/y\t0.512s")
        XCTAssertEqual(o?.framework, "go"); XCTAssertTrue(o?.green == true)
    }

    func test_go_fail() {
        let o = TestOutcomeDetector.detect(in: "FAIL\tgithub.com/x/y\t0.1s")
        XCTAssertEqual(o?.framework, "go"); XCTAssertEqual(o?.failed, 1)
    }

    func test_noFalsePositiveOnProse() {
        XCTAssertNil(TestOutcomeDetector.detect(in: "The build passed and everything looks great now."))
        XCTAssertNil(TestOutcomeDetector.detect(in: "I will run the tests next."))
    }
}
