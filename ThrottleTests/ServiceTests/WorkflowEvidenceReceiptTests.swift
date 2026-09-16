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

    func test_inputDigestsAreOrderInsensitiveAllowlistedAndOptional() throws {
        let untracked = WorkflowEvidenceReceipt.digest(ofUntracked: ["b.txt", "a/c.log", "b.txt", ""])
        XCTAssertEqual(untracked, WorkflowEvidenceReceipt.digest(ofUntracked: ["a/c.log", "b.txt"]))
        XCTAssertNotEqual(untracked, WorkflowEvidenceReceipt.digest(ofUntracked: []))
        XCTAssertEqual(untracked.count, 64)

        let base = ["PATH": "/usr/bin", "DEVELOPER_DIR": "/Applications/Xcode.app", "HOME": "/Users/a"]
        var leaked = base
        leaked["ANTHROPIC_API_KEY"] = "sk-synthetic"
        leaked["HOME"] = "/Users/b"
        XCTAssertEqual(WorkflowEvidenceReceipt.digest(environment: base, toolchain: "Xcode 26.6"),
                       WorkflowEvidenceReceipt.digest(environment: leaked, toolchain: "Xcode 26.6"),
                       "only allowlisted keys shape the digest; secrets and HOME never do")
        XCTAssertNotEqual(WorkflowEvidenceReceipt.digest(environment: base, toolchain: "Xcode 26.6"),
                          WorkflowEvidenceReceipt.digest(environment: base, toolchain: "Xcode 26.5"))

        // A receipt written before the digests existed still decodes, with nothing claimed.
        let data = try JSONEncoder().encode(command)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["untrackedDigest"])
        let decoded = try JSONDecoder().decode(WorkflowEvidenceReceipt.self, from: data)
        XCTAssertNil(decoded.untrackedDigest)
        XCTAssertNil(decoded.environmentDigest)
        XCTAssertFalse(decoded.provesCompleteTests())
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

    func testContractRequiresIndependentTestObligationsAndCurrentInputs() {
        var contract = WorkflowVerificationContract(revision: 1, requiredTests: ["one", "two"])
        var receipt = command
        receipt.contractDigest = contract.digest
        XCTAssertFalse(contract.accepts(nil, stamp: "task+base"))
        XCTAssertFalse(contract.accepts(receipt, stamp: "task+base"))
        receipt.scope = .testInventory
        receipt.expectedTests = ["one"]
        receipt.passedTests = ["one"]
        receipt.skippedTests = []
        XCTAssertTrue(receipt.provesCompleteTests(), "the bundle can describe a smaller suite")
        XCTAssertFalse(contract.accepts(receipt, stamp: "task+base"))
        receipt.expectedTests = ["one", "two"]
        receipt.passedTests = ["one", "two"]
        XCTAssertTrue(contract.accepts(receipt, stamp: "task+base"))
        XCTAssertFalse(contract.accepts(receipt, stamp: "new+base"))
        contract.revision = 2
        XCTAssertFalse(contract.accepts(receipt, stamp: "task+base"))
        contract.revision = 1
        contract.requiredTests = ["one"]
        XCTAssertFalse(contract.accepts(receipt, stamp: "task+base"), "silent weakening invalidates the receipt")
    }

    func testContractRejectsInvalidRequirementsAndUnapprovedSkips() throws {
        var contract = WorkflowVerificationContract(revision: 1, requiredTests: ["one", "two"])
        var receipt = command
        receipt.scope = .testInventory
        receipt.expectedTests = ["one", "two"]
        receipt.passedTests = ["one"]
        receipt.skippedTests = ["two"]
        receipt.contractDigest = contract.digest
        XCTAssertFalse(contract.accepts(receipt, stamp: "task+base"))
        contract.allowedSkips = ["two"]
        receipt.contractDigest = contract.digest
        XCTAssertTrue(contract.accepts(receipt, stamp: "task+base"))
        let decoded = try JSONDecoder().decode(WorkflowVerificationContract.self,
                                               from: JSONEncoder().encode(contract))
        XCTAssertEqual(decoded.digest, contract.digest)
        for requirements in [[], [""], ["  "], ["one", "one"]] {
            contract.requiredTests = requirements
            XCTAssertNil(contract.digest)
            XCTAssertFalse(contract.accepts(receipt, stamp: "task+base"))
        }
        contract.requiredTests = ["one", "two"]
        contract.schemaVersion = 99
        XCTAssertNil(contract.digest)
    }
}
