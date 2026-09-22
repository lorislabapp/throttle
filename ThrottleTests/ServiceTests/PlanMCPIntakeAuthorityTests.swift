import Darwin
@testable import Throttle
import XCTest

final class PlanMCPIntakeAuthorityTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("intake-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func grant(_ root: URL, operations: Set<PlanMCPAuthority.Operation>) -> PlanMCPAuthority {
        PlanMCPAuthority(projectRoots: [root], author: "researcher", operations: operations,
                         taskID: "intake", missionID: UUID(), issuedAt: Date(),
                         expiresAt: Date().addingTimeInterval(60))
    }

    private func route(_ tool: String, root: URL, grant: PlanMCPAuthority?) -> String {
        var result = ""
        PlanMCPTools.routeCall(name: tool, arguments: ["project": root.path, "by": "researcher",
            "pillar": ViabilityPillar.allCases[0].rawValue, "claim": "Synthetic finding",
            "source": "fixture:source", "rating": 2], authority: .success(grant),
            onResult: { result = $0 }, onError: { result = "RPC error: \($0)" })
        return result
    }

    func testAbsentOrTaskOnlyGrantCannotBootstrapOrWriteResearch() throws {
        let root = try root()
        for tool in ["throttle_plan_bootstrap", "throttle_research_record", "throttle_viability_read"] {
            XCTAssertTrue(route(tool, root: root, grant: nil).hasPrefix("Refused:"))
        }
        for tool in ["throttle_plan_bootstrap", "throttle_research_record"] {
            XCTAssertTrue(route(tool, root: root, grant: grant(root, operations: [.event])).hasPrefix("Refused:"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".throttle").path))
    }

    func testIntakeRequiresExactProjectAndExplicitOperations() throws {
        let root = try root()
        let sibling = try self.root()
        XCTAssertTrue(route("throttle_plan_bootstrap", root: sibling,
                            grant: grant(root, operations: [.bootstrap])).hasPrefix("Refused:"))
        XCTAssertTrue(route("throttle_plan_bootstrap", root: root,
                            grant: grant(root, operations: [.bootstrap])).contains("Created a plan"))
        XCTAssertTrue(route("throttle_research_record", root: root,
                            grant: grant(root, operations: [.research])).contains("Recorded under"))
        XCTAssertTrue(route("throttle_viability_read", root: root,
                            grant: grant(root, operations: [.read])).contains("Synthetic finding"))
    }

    func testGrantReplacementCannotWidenAnAdmittedRequest() throws {
        let root = try root()
        var current = grant(root, operations: [.read])
        let check = PlanMCPTools.pinnedAuthorization("throttle_viability_read", ["project": root.path],
                                                    load: { .success(current) })
        XCTAssertNil(check())
        current.operations.insert(.bootstrap)
        XCTAssertTrue(check()?.contains("authority changed") == true)
    }

    func testCorruptResearchIsNotOverwrittenAndRevokedMutationDoesNotCreateIt() throws {
        let root = try root()
        let store = ResearchDossierStore(projectRoot: root)
        let finding = ResearchFinding(pillar: ViabilityPillar.allCases[0], claim: "fixture",
                                      source: "fixture:source", rating: 2, recordedBy: "researcher")
        XCTAssertThrowsError(try store.record(finding, authorizeMutation: { "Refused: revoked" }))
        let directory = root.appendingPathComponent(".throttle")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("research.json")
        let broken = Data("{broken".utf8)
        try broken.write(to: file)
        XCTAssertThrowsError(try store.record(finding))
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }

    func testResearchReaderRefusesLinksSpecialFilesAndOversizedInput() throws {
        let root = try root()
        let directory = root.appendingPathComponent(".throttle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("research.json")
        let target = root.appendingPathComponent("outside.json")
        let bytes = Data("{}".utf8)
        try bytes.write(to: target)
        let store = ResearchDossierStore(projectRoot: root)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try store.loadValidated())
        try FileManager.default.removeItem(at: file)
        try FileManager.default.linkItem(at: target, to: file)
        XCTAssertThrowsError(try store.loadValidated())
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        XCTAssertThrowsError(try store.loadValidated())
        try FileManager.default.removeItem(at: file)
        try Data(repeating: 32, count: 4 * 1_024 * 1_024 + 1).write(to: file)
        XCTAssertThrowsError(try store.loadValidated())
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    func testConcurrentResearchWritersPreserveEveryFinding() async throws {
        let root = try root()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    try ResearchDossierStore(projectRoot: root).record(ResearchFinding(
                        pillar: ViabilityPillar.allCases[0], claim: "fixture-\(index)",
                        source: "fixture:source", rating: 2, recordedBy: "researcher"))
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(try ResearchDossierStore(projectRoot: root).loadValidated().findings.count, 8)
    }
}
