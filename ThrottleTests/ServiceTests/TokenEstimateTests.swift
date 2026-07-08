import XCTest
@testable import Throttle

final class TokenEstimateTests: XCTestCase {

    func test_defaultIsDense() {
        // Default kind is .dense (/3) — most estimate sites measure code/JSON/schemas.
        XCTAssertEqual(TokenEstimate.fromBytes(300), 100)
    }

    func test_proseVsDense_ratio() {
        let bytes = 3000
        XCTAssertEqual(TokenEstimate.fromBytes(bytes, kind: .prose), 750)   // /4
        XCTAssertEqual(TokenEstimate.fromBytes(bytes, kind: .dense), 1000)  // /3
        // Dense (Opus 4.7+ tokenizer on code) ≈ 33% higher than the old /4 prose rule.
        XCTAssertEqual(Double(TokenEstimate.fromBytes(bytes, kind: .dense))
                     / Double(TokenEstimate.fromBytes(bytes, kind: .prose)),
                       4.0 / 3.0, accuracy: 0.02)
    }

    func test_zeroAndNegative() {
        XCTAssertEqual(TokenEstimate.fromBytes(0), 0)
        XCTAssertEqual(TokenEstimate.fromBytes(-10), 0)
    }
}
