@testable import Throttle
import XCTest

final class LocalDelegationServiceTests: XCTestCase {
    func testAllowsOnlyBoundedTaskKinds() {
        XCTAssertEqual(
            LocalDelegationService.assess(kind: "extract", objective: "Extract exact error messages"),
            .allow(.extract)
        )
        guard case .escalate = LocalDelegationService.assess(kind: "execute", objective: "Run tests") else {
            return XCTFail("Unsupported execution must escalate")
        }
        guard case .escalate = LocalDelegationService.assess(kind: "summarize", objective: "Run the command and publish the release") else {
            return XCTFail("State-changing objective must escalate")
        }
    }

    func testValidatesExactEvidenceAsVerified() {
        let source = "Build complete. 231 tests passed. Zero failures."
        let raw = #"{"result":"The suite passed.","evidence":["231 tests passed","Zero failures"],"confidence":"high"}"#
        let result = LocalDelegationService.validate(raw: raw, source: source, kind: .extract)
        XCTAssertEqual(result.status, "verified")
        XCTAssertEqual(result.evidence.count, 2)
    }

    func testSynthesisStaysReviewRequiredEvenWithExactQuotes() {
        let source = "Build complete. 231 tests passed. Zero failures."
        let raw = #"{"result":"The suite passed.","evidence":["231 tests passed","Zero failures"],"confidence":"high"}"#
        let result = LocalDelegationService.validate(raw: raw, source: source, kind: .summarize)
        XCTAssertEqual(result.status, "review_required")
    }

    func testInventedEvidenceRequiresReviewAndIsNotRepeated() {
        let raw = #"{"result":"The suite passed.","evidence":["999 tests passed"],"confidence":"high"}"#
        let result = LocalDelegationService.validate(raw: raw, source: "231 tests passed", kind: .extract)
        XCTAssertEqual(result.status, "review_required")
        XCTAssertTrue(result.evidence.isEmpty)
    }

    func testDraftAlwaysRequiresPlannerReview() {
        let raw = #"{"result":"Candidate release note","evidence":[],"confidence":"low"}"#
        let result = LocalDelegationService.validate(raw: raw, source: "source", kind: .draft)
        XCTAssertEqual(result.status, "review_required")
    }

    func testMalformedOutputEscalates() {
        let result = LocalDelegationService.validate(raw: "not json", source: "source", kind: .summarize)
        XCTAssertEqual(result.status, "escalate")
    }
}
