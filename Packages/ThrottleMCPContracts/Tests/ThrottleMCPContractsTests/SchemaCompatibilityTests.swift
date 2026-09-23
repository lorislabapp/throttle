import Foundation
import ThrottleMCPContracts
import XCTest

final class SchemaCompatibilityTests: XCTestCase {
    func testCatalogMatchesPreExtractionJSON() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "pre-extraction-tools", withExtension: "json", subdirectory: "Fixtures"
        ))
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        XCTAssertEqual(try canonical(ThrottleMCPSchemas.all), try canonical(reference))
    }

    func testCatalogContainsExactlyTheEightUniqueToolNames() {
        let names = ThrottleMCPSchemas.all.compactMap { $0["name"] as? String }
        XCTAssertEqual(names.count, 8)
        XCTAssertEqual(Set(names), [
            "throttle_plan_read", "throttle_task_claim", "throttle_task_event",
            "throttle_task_verdict", "throttle_research_record", "throttle_viability_read",
            "throttle_plan_bootstrap", "throttle_project_explore"
        ])
    }

    func testEveryRequiredFieldIsDeclaredIncludingNestedReports() throws {
        for tool in ThrottleMCPSchemas.all {
            XCTAssertFalse(try XCTUnwrap(tool["description"] as? String).isEmpty)
            let input = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            XCTAssertEqual(input["type"] as? String, "object")
            try checkRequiredFields(input)
        }
    }

    func testRetryFieldsKeepLegacyOptionalityAndSafeIntegerLimit() throws {
        for tool in [ThrottleMCPSchemas.taskClaimSchema(), ThrottleMCPSchemas.taskEventSchema(),
                     ThrottleMCPSchemas.taskVerdictSchema()] {
            let input = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            let required = try XCTUnwrap(input["required"] as? [String])
            XCTAssertFalse(required.contains("event_id"))
            XCTAssertFalse(required.contains("expected_seq"))
            let properties = try XCTUnwrap(input["properties"] as? [String: [String: Any]])
            XCTAssertEqual(properties["event_id"]?["format"] as? String, "uuid")
            XCTAssertEqual(properties["expected_seq"]?["type"] as? String, "integer")
            XCTAssertEqual(properties["expected_seq"]?["minimum"] as? Int, 0)
            XCTAssertEqual(properties["expected_seq"]?["maximum"] as? Int, 9_007_199_254_740_991)
        }
    }

    func testReviewContractKeepsEvidenceAndCandidateBindingRequired() throws {
        let input = try XCTUnwrap(ThrottleMCPSchemas.taskVerdictSchema()["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(input["properties"] as? [String: [String: Any]])
        let review = try XCTUnwrap(properties["review_report"])
        let required = try XCTUnwrap(review["required"] as? [String])
        for field in ["taskID", "workContractDigest", "rubricDigest", "candidateStamp", "assessments"] {
            XCTAssertTrue(required.contains(field), field)
        }
        let fields = try XCTUnwrap(review["properties"] as? [String: [String: Any]])
        XCTAssertEqual(fields["reviewerKind"]?["enum"] as? [String], ["model"])
        let assessment = try XCTUnwrap(fields["assessments"]?["items"] as? [String: Any])
        XCTAssertEqual(assessment["required"] as? [String], ["criterionID", "outcome", "evidence"])
    }

    func testConsumerChangesCannotMutateTheCanonicalCatalog() throws {
        let original = try canonical(ThrottleMCPSchemas.all)
        var changed = ThrottleMCPSchemas.all
        changed[0]["name"] = "consumer_override"
        changed[1]["inputSchema"] = ["type": "null"]
        XCTAssertNotEqual(try canonical(changed), original)
        XCTAssertEqual(try canonical(ThrottleMCPSchemas.all), original)
    }

    private func canonical(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func checkRequiredFields(_ schema: [String: Any]) throws {
        if schema["type"] as? String == "object" {
            let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
            let required = try XCTUnwrap(schema["required"] as? [String])
            XCTAssertEqual(required.count, Set(required).count)
            XCTAssertTrue(Set(required).isSubset(of: Set(properties.keys)))
            for child in properties.values { try checkRequiredFields(child) }
        }
        if schema["type"] as? String == "array" {
            try checkRequiredFields(XCTUnwrap(schema["items"] as? [String: Any]))
        }
    }
}
