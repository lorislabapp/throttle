import XCTest
@testable import Throttle

/// Tests for the Dead-Skill audit's MCP token-tax accounting — the CFO number
/// "≈N tokens/session paid for loaded-but-unused MCP servers".
final class DeadSkillServiceTests: XCTestCase {

    private func mcp(_ name: String, uses: Int) -> DeadSkillRow {
        DeadSkillRow(name: name, kind: .mcp, uses: uses, lastUsed: nil, loaded: true)
    }

    func test_folding_countsOnlyDeadAndProbedMCP() {
        let report = DeadSkillReport(rows: [
            mcp("alpha", uses: 0),   // dead + probed  → counts
            mcp("beta",  uses: 5),   // alive          → excluded
            mcp("gamma", uses: 0),   // dead, no probe → excluded (unknown cost)
            DeadSkillRow(name: "skill-x", kind: .skill, uses: 0, lastUsed: nil, loaded: true), // skill → excluded
        ], filesScanned: 1, windowDays: 30)

        let folded = DeadSkillService.folding(report, withProbe: ["alpha": 3200, "beta": 999, "skill-x": 50])
        XCTAssertEqual(folded.deadMCPTokens, 3200, "only alpha is dead, MCP, and probed")
    }

    func test_folding_sumsMultipleDeadServers() {
        let report = DeadSkillReport(rows: [mcp("a", uses: 0), mcp("b", uses: 0)],
                                     filesScanned: 1, windowDays: 30)
        let folded = DeadSkillService.folding(report, withProbe: ["a": 1500, "b": 2500])
        XCTAssertEqual(folded.deadMCPTokens, 4000)
    }

    func test_deadMCPTokens_zeroWithoutProbe() {
        let report = DeadSkillReport(rows: [mcp("a", uses: 0)], filesScanned: 1, windowDays: 30)
        XCTAssertEqual(report.deadMCPTokens, 0, "no probe data → no claimed cost")
    }

    func test_folding_doesNotMutateOriginal() {
        let report = DeadSkillReport(rows: [mcp("a", uses: 0)], filesScanned: 1, windowDays: 30)
        _ = DeadSkillService.folding(report, withProbe: ["a": 1234])
        XCTAssertNil(report.rows.first?.schemaTokensEst, "folding returns a copy; original untouched")
    }
}
