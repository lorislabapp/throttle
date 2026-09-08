@testable import Throttle
import XCTest

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

    func test_failureFirstAndErrorOnlyPytestSummaries() {
        for text in ["=== 2 failed, 10 passed in 1.23s ===", "=== 1 error in 0.20s ==="] {
            let result = TestOutcomeDetector.detect(in: text)
            XCTAssertNotNil(result, text)
            XCTAssertFalse(result?.green == true, text)
        }
    }

    func test_laterSuccessDoesNotEraseFailureInTheSameObservedTail() {
        let text = "test result: FAILED. 1 passed; 2 failed; 0 ignored;\n"
            + "test result: ok. 8 passed; 0 failed; 0 ignored;"
        XCTAssertFalse(TestOutcomeDetector.detect(in: text)?.green == true)
        let swift = "Executed 3 tests, with 2 failures (0 unexpected)\n"
            + "Executed 8 tests, with 0 failures (0 unexpected)"
        XCTAssertFalse(TestOutcomeDetector.detect(in: swift)?.green == true)
    }

    func test_failureFromAnotherRunnerCannotBecomeGreen() {
        let text = "=== 12 passed in 1.0s ===\nFAIL\texample.com/pkg\t0.1s"
        XCTAssertFalse(TestOutcomeDetector.detect(in: text)?.green == true)
    }

    func test_summaryMentionedInProseIsNotObservedResult() {
        XCTAssertNil(TestOutcomeDetector.detect(in: "Earlier I saw 12 passed in 1.0s and continued."))
        XCTAssertNil(TestOutcomeDetector.detect(in: "Example: Executed 12 tests, with 0 failures"))
    }

    func test_invalidAndEmptyCountsCannotBecomeGreen() {
        for text in ["=== 0 passed in 1.0s ===", "Executed 1 tests, with 2 failures",
                     "test result: FAILED. 12 passed; 0 failed; 0 ignored;"] {
            XCTAssertFalse(TestOutcomeDetector.detect(in: text)?.green == true, text)
        }
    }

    func test_ansiColourAndCachedGoOutput() {
        XCTAssertTrue(TestOutcomeDetector.detect(in: "\u{001B}[32m=== 12 passed in 1.0s ===\u{001B}[0m")?.green == true)
        XCTAssertTrue(TestOutcomeDetector.detect(in: "ok\texample.com/pkg\t(cached)")?.green == true)
    }

    func test_swiftTestingOrNodeFailureAfterXCTestSuccessIsNotGreen() {
        for failure in ["✘ Test run with 8 tests failed after 0.001 seconds with 11 issues.",
                        "ℹ fail 3", "=== 1 passed, 999999999999999999999999 failed in 1.0s ==="] {
            let text = "Executed 15 tests, with 0 failures (0 unexpected)\n" + failure
            XCTAssertFalse(TestOutcomeDetector.detect(in: text)?.green == true)
        }
    }
}
