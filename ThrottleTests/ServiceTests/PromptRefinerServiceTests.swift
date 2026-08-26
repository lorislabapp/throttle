@testable import Throttle
import XCTest

/// The refiner proposes; the user applies. These tests pin the invariants that
/// make that promise true: a payload can never carry its own Enter, control
/// bytes never reach a live PTY, and the cost shown is the cost measured.
final class PromptRefinerServiceTests: XCTestCase {

    // MARK: - Insertion payload

    func test_insertionPayload_stripsTrailingNewlinesSoInsertNeverFires() {
        XCTAssertEqual(PromptRefinerService.insertionPayload("fix the scroll\n"), "fix the scroll")
        XCTAssertEqual(PromptRefinerService.insertionPayload("fix the scroll\n\n\n"), "fix the scroll")
        XCTAssertEqual(PromptRefinerService.insertionPayload("a\nb\n"), "a\nb")
    }

    func test_insertionPayload_keepsInteriorNewlines() {
        XCTAssertEqual(PromptRefinerService.insertionPayload("one\ntwo\nthree"), "one\ntwo\nthree")
    }

    // MARK: - Validation

    func test_validate_rejectsEscapeAndNul() {
        XCTAssertThrowsError(try PromptRefinerService.validate("safe \u{1b}[31m red")) { error in
            XCTAssertEqual(error as? PromptRefinerService.RefinerError, .controlSequence)
        }
        XCTAssertThrowsError(try PromptRefinerService.validate("safe \u{0} nul")) { error in
            XCTAssertEqual(error as? PromptRefinerService.RefinerError, .controlSequence)
        }
    }

    func test_validate_acceptsOrdinaryMultilinePrompt() {
        XCTAssertNoThrow(try PromptRefinerService.validate("line one\nline two\n\ttabbed"))
    }

    func test_validate_rejectsOverOneMebibyte() {
        let big = String(repeating: "a", count: 1024 * 1024 + 1)
        XCTAssertThrowsError(try PromptRefinerService.validate(big)) { error in
            XCTAssertEqual(error as? PromptRefinerService.RefinerError, .tooLarge)
        }
    }

    // MARK: - Metrics

    func test_metrics_countsLinesBytesAndApproxTokens() {
        let m = PromptRefinerService.metrics("abcd\nefgh")
        XCTAssertEqual(m.lines, 2)
        XCTAssertEqual(m.bytes, 9)
        XCTAssertEqual(m.approxTokens, 2)   // bytes / 4, floor 1
    }

    func test_metrics_emptyTextIsZeroLinesAndOneToken() {
        let m = PromptRefinerService.metrics("")
        XCTAssertEqual(m.lines, 0)
        XCTAssertEqual(m.bytes, 0)
        XCTAssertEqual(m.approxTokens, 1)
    }
}
