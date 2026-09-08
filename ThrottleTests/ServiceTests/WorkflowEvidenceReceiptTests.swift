@testable import Throttle
import XCTest

final class WorkflowEvidenceReceiptTests: XCTestCase {
    private var command: WorkflowEvidenceReceipt {
        .command("synthetic-check", stamp: "task+base", startedAt: Date(timeIntervalSince1970: 1),
                 finishedAt: Date(timeIntervalSince1970: 2), result: (true, true))
    }

    func test_commandSuccessDoesNotProveTests() {
        XCTAssertEqual(command.outcome, .passed)
        XCTAssertFalse(command.provesCompleteTests())
    }

    func test_changedInputsAreIncompleteEvenWithExitZero() {
        let receipt = WorkflowEvidenceReceipt.command("true", stamp: "a+b", startedAt: Date(),
            finishedAt: Date(), result: (true, false))
        XCTAssertEqual(receipt.outcome, .incomplete)
    }

    func test_testInventoryRequiresExactCoverageAndExplicitSkips() {
        var receipt = command
        receipt.scope = .testInventory
        receipt.expectedTests = ["one", "two"]
        receipt.passedTests = ["one"]
        receipt.skippedTests = ["two"]
        XCTAssertFalse(receipt.provesCompleteTests())
        XCTAssertTrue(receipt.provesCompleteTests(allowedSkips: ["two"]))
        receipt.passedTests = ["one", "one"]
        XCTAssertFalse(receipt.provesCompleteTests(allowedSkips: ["two"]))
        receipt.passedTests = ["one", "two"]
        XCTAssertFalse(receipt.provesCompleteTests(allowedSkips: ["two"]))
        receipt.skippedTests = []
        XCTAssertTrue(receipt.provesCompleteTests())
        receipt.expectedTests = []
        XCTAssertFalse(receipt.provesCompleteTests())
    }

    func test_unknownSchemaAndMissingEvidenceAreNotPromoted() throws {
        var receipt = command
        receipt.schemaVersion = 99
        XCTAssertFalse(receipt.provesCompleteTests())
        let legacy = Data(#"{"seq":1,"at":0,"by":"synthetic","type":"checked","ok":true}"#.utf8)
        let event = try JSONDecoder().decode(TaskEvent.self, from: legacy)
        XCTAssertNil(event.receipt)
        XCTAssertNil(event.eventID)
    }
}
