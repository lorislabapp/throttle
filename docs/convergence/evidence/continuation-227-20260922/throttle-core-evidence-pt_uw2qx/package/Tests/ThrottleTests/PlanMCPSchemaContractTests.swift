@testable import Throttle
import ThrottleMCPContracts
import XCTest

final class PlanMCPSchemaContractTests: XCTestCase {
    func testProductFacadesUseTheCanonicalSchemas() throws {
        let product = [
            PlanMCPTools.planReadSchema(), PlanMCPTools.taskClaimSchema(),
            PlanMCPTools.taskEventSchema(), PlanMCPTools.taskVerdictSchema(),
            PlanMCPTools.researchRecordSchema(), PlanMCPTools.viabilitySchema(),
            PlanMCPTools.planBootstrapSchema(), ProjectKnowledgeMCP.schema
        ]
        XCTAssertEqual(try canonical(product), try canonical(ThrottleMCPSchemas.all))
        XCTAssertEqual(try canonical(PlanMCPTools.schemas), try canonical(ThrottleMCPSchemas.planTools))
    }

    func testResearchPillarsMatchTheProductModel() throws {
        let fields = try properties(ThrottleMCPSchemas.researchRecordSchema())
        XCTAssertEqual(fields["pillar"]?["enum"] as? [String], ViabilityPillar.allCases.map(\.rawValue))
    }

    func testEventAndExplorerEnumsMatchTheProductModels() throws {
        let events = try properties(ThrottleMCPSchemas.taskEventSchema())
        let allowed: [TaskEventType] = [.progress, .evidence, .blocked, .unblocked,
                                        .candidateComplete, .failed, .released]
        XCTAssertEqual(events["type"]?["enum"] as? [String], allowed.map(\.rawValue))
        let explorer = try properties(ThrottleMCPSchemas.projectExploreSchema())
        let operations: [ProjectKnowledgeOperation] = [.list, .search, .read]
        XCTAssertEqual(explorer["operation"]?["enum"] as? [String], operations.map(\.rawValue))
    }

    func testEveryCatalogEntryHasAProductRoute() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("schema-route-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        for tool in ThrottleMCPSchemas.all {
            let name = try XCTUnwrap(tool["name"] as? String)
            var responses = 0
            PlanMCPTools.routeCall(name: name, arguments: ["project": root.path], onResult: { _ in
                responses += 1
            }, onError: { error in
                responses += 1
                XCTAssertFalse(String(describing: error).contains("Unknown tool:"), name)
            })
            XCTAssertEqual(responses, 1, name)
        }
        var unknownRejected = false
        PlanMCPTools.routeCall(name: "throttle_unknown", arguments: ["project": root.path], onResult: { _ in
            XCTFail("An unknown tool must not execute")
        }, onError: { unknownRejected = String(describing: $0).contains("Unknown tool:") })
        XCTAssertTrue(unknownRejected)
    }

    private func canonical(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func properties(_ tool: [String: Any]) throws -> [String: [String: Any]] {
        let input = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        return try XCTUnwrap(input["properties"] as? [String: [String: Any]])
    }
}
