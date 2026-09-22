import Foundation
import Testing
@testable import Throttle

@Suite("Workflow technology reuse")
struct WorkflowTechnologyReuseTests {
    @Test("catalog visibility and reuse rights are separate gates")
    func discoverableDoesNotMeanReusable() {
        var entry = catalogEntry()
        entry.reusableByProjects = []
        let result = WorkflowTechnologyReuseEvaluator.evaluate(request: request(), entry: entry)
        #expect(!result.eligible)
        #expect(result.blockers == ["catalog_entry_not_reusable"])
    }

    @Test("a changed source revision invalidates the earlier reuse evaluation")
    func sourceRevisionIsPinned() {
        var entry = catalogEntry()
        entry.sourceRevision = String(repeating: "b", count: 40)
        let result = WorkflowTechnologyReuseEvaluator.evaluate(request: request(), entry: entry)
        #expect(!result.eligible)
        #expect(result.blockers == ["source_revision_stale"])
    }

    @Test("MCP is valid only when the catalog records an actual MCP interface")
    func mcpMustExist() {
        var value = request()
        value.proposedMode = .bridgeViaMCP
        let result = WorkflowTechnologyReuseEvaluator.evaluate(request: value, entry: catalogEntry())
        #expect(!result.eligible)
        #expect(result.blockers == ["mcp_interface_absent"])
    }

    @Test("an eligible result is an advisory integration mode, not a mutation")
    func eligibleReuseDecision() {
        let result = WorkflowTechnologyReuseEvaluator.evaluate(request: request(), entry: catalogEntry())
        #expect(result.eligible)
        #expect(result.score == 100)
        #expect(result.blockers.isEmpty)
    }

    private func catalogEntry() -> WorkflowTechnologyCatalogEntry {
        WorkflowTechnologyCatalogEntry(
            id: "technology://throttle/package/evidence-kit",
            kind: .package,
            name: "EvidenceKit",
            sourceRevision: String(repeating: "a", count: 40),
            sourcePath: "Packages/EvidenceKit",
            ownerProject: "throttle",
            privacy: .privateAsset,
            discoverableByProjects: ["throttle", "new-product"],
            reusableByProjects: ["throttle", "new-product"],
            capabilities: ["evidence.receipts"],
            interfaces: [.swiftAPI],
            lifecycle: .maintained,
            evidenceRefs: ["catalog://scan/1"],
            lastSeenAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func request() -> WorkflowTechnologyReuseRequest {
        WorkflowTechnologyReuseRequest(
            targetProject: "new-product",
            desiredCapability: "evidence.receipts",
            catalogEntryID: "technology://throttle/package/evidence-kit",
            expectedSourceRevision: String(repeating: "a", count: 40),
            factors: WorkflowReuseFactors(
                functionalFit: 1,
                interfaceFit: 1,
                quality: 1,
                maturity: 1,
                health: 1,
                accessibility: 1,
                existingUsage: 1,
                knowledgeConfidence: 1,
                penalty: 0
            ),
            proposedMode: .reuseDirectly,
            rationale: ["The package boundary already matches the capability."]
        )
    }
}
