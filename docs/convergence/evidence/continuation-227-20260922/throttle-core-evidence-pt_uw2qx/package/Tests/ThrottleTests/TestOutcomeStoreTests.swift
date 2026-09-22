@testable import Throttle
import XCTest

final class TestOutcomeStoreTests: XCTestCase {
    func test_failedAttemptsContributeToCostPerGreen() {
        let summary = fold([row(1, failed: 1, cost: "2"), row(2, cost: "5")])
        XCTAssertEqual(summary.red, 1)
        XCTAssertEqual(summary.green, 1)
        XCTAssertEqual(summary.eurPerGreen, 5)
    }

    func test_windowUsesHistoricalCostAnchor() {
        let summary = fold([row(1, cost: "20"), row(11, failed: 1, cost: "22"), row(12, cost: "25")], cutoff: 10)
        XCTAssertEqual(summary.eurPerGreen, 5)
        XCTAssertEqual(summary.green, 1)
        XCTAssertEqual(summary.red, 1)
    }

    func test_missingCostsAndResetsCannotMakeMetricCheaper() {
        for rows in [[row(1), row(2, cost: "5")],
                     [row(1, cost: "5"), row(2, cost: "2")],
                     [row(1, cost: "-1"), row(2, cost: "2")]] {
            XCTAssertNil(fold(rows).eurPerGreen)
        }
        XCTAssertNil(fold([row(1), row(11, cost: "20")], cutoff: 10).eurPerGreen)
    }

    func test_malformedOrEmptyResultsCannotBecomeGreen() {
        let summary = fold(["{}", "not json", "{\"ts\":1,\"project\":\"p\",\"passed\":2}",
                            row(1, passed: -1), row(2, passed: 0)])
        XCTAssertFalse(summary.hasData)
        XCTAssertNil(summary.eurPerGreen)
    }

    func test_stableOrderAndIndependentSessions() {
        let summary = fold([row(1, failed: 1, cost: "2"), row(1, cost: "5"),
                            row(2, cost: "3", session: "b")])
        XCTAssertEqual(summary.eurPerGreen, 4)
        XCTAssertEqual(summary.green, 2)
    }

    func test_unrelatedProjectsAndAllFailuresDoNotCreateCostPerGreen() {
        XCTAssertFalse(TestOutcomeStore.summarize(text: row(1, cost: "10"), project: "other", cutoff: 0).hasData)
        XCTAssertNil(fold([row(1, failed: 1, cost: "10")]).eurPerGreen)
    }

    private func fold(_ rows: [String], cutoff: Int = 0) -> TestOutcomeStore.Summary {
        TestOutcomeStore.summarize(text: rows.joined(separator: "\n"), project: "p", cutoff: cutoff)
    }

    private func row(_ timestamp: Int, passed: Int = 1, failed: Int = 0,
                     cost: String? = nil, session: String = "a") -> String {
        let price = cost.map { ",\"eur\":\($0)" } ?? ""
        return "{\"ts\":\(timestamp),\"project\":\"p\",\"sid\":\"\(session)\","
            + "\"passed\":\(passed),\"failed\":\(failed)\(price)}"
    }
}
