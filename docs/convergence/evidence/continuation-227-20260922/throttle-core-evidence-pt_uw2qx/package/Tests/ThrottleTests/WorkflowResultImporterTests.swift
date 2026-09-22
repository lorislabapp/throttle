@testable import Throttle
import XCTest

/// A receipt may only claim complete test coverage from an inventory Xcode
/// actually recorded. These pin what the importer will and will not read out
/// of that inventory.
final class WorkflowResultImporterTests: XCTestCase {

    private func tree(_ cases: [(String, String)]) throws -> Data {
        let nodes: [[String: Any]] = [[
            "nodeType": "Test Plan", "name": "Throttle",
            "children": [[
                "nodeType": "Unit test bundle", "name": "ThrottleTests",
                "children": cases.map { identifier, result -> [String: Any] in
                    ["nodeType": "Test Case", "nodeIdentifier": identifier, "result": result]
                }
            ]]
        ]]
        return try JSONSerialization.data(withJSONObject: ["testNodes": nodes])
    }

    func test_theInventoryIsReadFromWhateverDepthTheCasesSitAt() throws {
        let inventory = try WorkflowResultImporter.inventory(fromTestsJSON: tree([
            ("SuiteB/testTwo()", "Passed"),
            ("SuiteA/testOne()", "Passed"),
            ("SuiteA/testSkipped()", "Skipped"),
            ("SuiteA/testBroken()", "Failed")
        ]))
        XCTAssertEqual(inventory.expected,
                       ["SuiteA/testBroken()", "SuiteA/testOne()", "SuiteA/testSkipped()", "SuiteB/testTwo()"])
        XCTAssertEqual(inventory.passed, ["SuiteA/testOne()", "SuiteB/testTwo()"])
        XCTAssertEqual(inventory.skipped, ["SuiteA/testSkipped()"])
        XCTAssertEqual(inventory.unresolved, ["SuiteA/testBroken()"])
        XCTAssertFalse(inventory.isComplete)
    }

    func test_aStateTheImporterDoesNotUnderstandIsUnresolvedNotPassed() throws {
        let inventory = try WorkflowResultImporter.inventory(fromTestsJSON: tree([
            ("A/one()", "Passed"), ("A/two()", "Expected Failure"), ("A/three()", "")
        ]))
        XCTAssertEqual(inventory.unresolved, ["A/three()", "A/two()"],
                       "an unfamiliar result is never quietly counted as a pass")
        XCTAssertFalse(inventory.isComplete)
    }

    func test_aMalformedOrEmptyTreeIsRefused() throws {
        XCTAssertThrowsError(try WorkflowResultImporter.inventory(fromTestsJSON: Data("nope".utf8))) {
            XCTAssertEqual($0 as? WorkflowResultImporter.ImportError, .bundleUnreadable("tests.json is not JSON"))
        }
        let empty = try JSONSerialization.data(withJSONObject: ["testNodes": []])
        XCTAssertThrowsError(try WorkflowResultImporter.inventory(fromTestsJSON: empty)) {
            XCTAssertEqual($0 as? WorkflowResultImporter.ImportError, .unexpectedShape("no testNodes"))
        }
        let plan = try JSONSerialization.data(withJSONObject: [
            "testNodes": [["nodeType": "Test Plan", "name": "Throttle"]]
        ])
        XCTAssertThrowsError(try WorkflowResultImporter.inventory(fromTestsJSON: plan)) {
            XCTAssertEqual($0 as? WorkflowResultImporter.ImportError, .noCases)
        }
        XCTAssertThrowsError(try WorkflowResultImporter.inventory(
            fromTestsJSON: tree([("A/one()", "Passed"), ("A/one()", "Passed")])
        )) {
            XCTAssertEqual($0 as? WorkflowResultImporter.ImportError, .unexpectedShape("duplicate case A/one()"))
        }
    }

    func test_anInventoryUpgradesAPassingCommandAndOnlyThat() throws {
        let inventory = try WorkflowResultImporter.inventory(fromTestsJSON: tree([
            ("A/one()", "Passed"), ("A/two()", "Skipped")
        ]))
        let passing = WorkflowEvidenceReceipt.command(
            "swift test", stamp: "a+b", startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2), result: (true, true)
        )
        let upgraded = WorkflowResultImporter.upgraded(passing, with: inventory)
        XCTAssertEqual(upgraded.scope, .testInventory)
        XCTAssertEqual(upgraded.outcome, .passed)
        XCTAssertTrue(upgraded.provesCompleteTests(allowedSkips: ["A/two()"]))
        XCTAssertFalse(upgraded.provesCompleteTests(), "a skip still needs the caller's blessing")
        XCTAssertEqual(upgraded.inputStamp, passing.inputStamp, "the upgrade changes the claim, not the run")

        let changedInputs = WorkflowEvidenceReceipt.command(
            "swift test", stamp: "a+b", startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2), result: (true, false)
        )
        XCTAssertEqual(WorkflowResultImporter.upgraded(changedInputs, with: inventory).scope, .command,
                       "an inventory does not rescue a run whose inputs moved underneath it")
        let failed = WorkflowEvidenceReceipt.command(
            "swift test", stamp: "a+b", startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2), result: (false, true)
        )
        XCTAssertEqual(WorkflowResultImporter.upgraded(failed, with: inventory).scope, .command)
    }

    func test_anIncompleteRunIsRecordedAsIncompleteNotPassed() throws {
        let inventory = try WorkflowResultImporter.inventory(fromTestsJSON: tree([
            ("A/one()", "Passed"), ("A/two()", "Failed")
        ]))
        let receipt = WorkflowResultImporter.upgraded(
            WorkflowEvidenceReceipt.command("swift test", stamp: "a+b",
                                            startedAt: Date(timeIntervalSince1970: 1),
                                            finishedAt: Date(timeIntervalSince1970: 2),
                                            result: (true, true)),
            with: inventory
        )
        XCTAssertEqual(receipt.outcome, .incomplete)
        XCTAssertFalse(receipt.provesCompleteTests(allowedSkips: ["A/two()"]))
    }

    func test_aMissingBundleIsNamedRatherThanGuessedAt() {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).xcresult")
        XCTAssertThrowsError(try WorkflowResultImporter.inventory(fromBundle: absent)) {
            XCTAssertEqual($0 as? WorkflowResultImporter.ImportError, .bundleUnreadable(absent.path))
        }
    }
}
