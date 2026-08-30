@testable import Throttle
import XCTest

/// The advisor never starts anything, so the risk is not a crash — it is a
/// confident wrong answer. These tests pin the two things that matter: that a
/// decision is only made when a real signal supports it, and that the machine
/// limit comes from measurement rather than from a constant tuned on one Mac.
final class DispatchAdvisorTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func task(_ title: String, kind: TaskKind = .build) -> PlanTask {
        PlanTask(id: "T1", title: title, kind: kind)
    }

    private func memory(totalGB: Int, usedGB: Int, sessions: Int = 0, sessionGB: Int = 0,
                        pressure: Int = 1, swapGB: Int = 0) -> MemoryHealth {
        MemoryHealth(totalBytes: UInt64(totalGB) * 1_000_000_000,
                     usedBytes: UInt64(usedGB) * 1_000_000_000,
                     swapUsedBytes: UInt64(swapGB) * 1_000_000_000,
                     pressureLevel: pressure,
                     claudeCount: sessions,
                     claudeRSSBytes: UInt64(sessions * sessionGB) * 1_000_000_000)
    }

    private func budget(_ runtime: AgentRuntime, used: Double,
                        resets: Date? = nil) -> RuntimeBudget {
        RuntimeBudget(runtime: runtime, usedPercent: used, resetsAt: resets)
    }

    private func inputs(task: PlanTask,
                        capabilities: [AgentRuntime: MissionCapabilityInventory] = [:],
                        budgets: [RuntimeBudget],
                        memory: MemoryHealth,
                        spendCap: Double = 1.0,
                        agentCost: Double = 1.0) -> DispatchInputs {
        DispatchInputs(task: task, capabilities: capabilities, budgets: budgets,
                       memory: memory, spendCapEUR: spendCap,
                       estimatedAgentCostEUR: agentCost, now: now)
    }

    // MARK: - Capability, the only hard signal

    func testSoleCapabilityHolderWinsWithHighConfidence() {
        let advice = DispatchAdvisor.advise(inputs(
            task: task("Run the notarize skill"),
            capabilities: [
                .claudeCode: MissionCapabilityInventory(skills: ["notarize"], mcpServers: []),
                .codex: MissionCapabilityInventory(skills: [], mcpServers: [])
            ],
            budgets: [budget(.claudeCode, used: 90), budget(.codex, used: 10)],
            memory: memory(totalGB: 16, usedGB: 8)))

        XCTAssertEqual(advice.runtime, .claudeCode)
        XCTAssertEqual(advice.confidence, .high)
        XCTAssertTrue(advice.reasons.contains { $0.contains("only Claude") })
    }

    /// Capability outranks headroom — but only while that runtime can still run.
    func testCapabilityIsAbandonedWhenThatRuntimeIsOutOfWindow() {
        let advice = DispatchAdvisor.advise(inputs(
            task: task("Run the notarize skill"),
            capabilities: [
                .claudeCode: MissionCapabilityInventory(skills: ["notarize"], mcpServers: []),
                .codex: MissionCapabilityInventory(skills: [], mcpServers: [])
            ],
            budgets: [budget(.claudeCode, used: 100), budget(.codex, used: 5)],
            memory: memory(totalGB: 16, usedGB: 8)))

        XCTAssertEqual(advice.runtime, .codex)
        XCTAssertTrue(advice.reasons.contains { $0.contains("out of window") })
    }

    func testTwoHoldersIsATieNotASignal() {
        let advice = DispatchAdvisor.advise(inputs(
            task: task("Run the notarize skill"),
            capabilities: [
                .claudeCode: MissionCapabilityInventory(skills: ["notarize"], mcpServers: []),
                .codex: MissionCapabilityInventory(skills: ["notarize"], mcpServers: [])
            ],
            budgets: [budget(.claudeCode, used: 50), budget(.codex, used: 52)],
            memory: memory(totalGB: 16, usedGB: 8)))

        XCTAssertEqual(advice.verdict, .abstain)
    }

    // MARK: - Abstention

    /// Nothing in the evidence says research suits one runtime over the other, so
    /// the advisor must not invent that preference.
    func testSimilarHeadroomAbstainsRatherThanGuessing() {
        let advice = DispatchAdvisor.advise(inputs(
            task: task("Analyse the competition", kind: .research),
            budgets: [budget(.claudeCode, used: 40), budget(.codex, used: 45)],
            memory: memory(totalGB: 64, usedGB: 10)))

        XCTAssertEqual(advice.verdict, .abstain)
        XCTAssertEqual(advice.fanOut, 0)
    }

    func testClearHeadroomGapDecidesWithMediumConfidence() {
        let advice = DispatchAdvisor.advise(inputs(
            task: task("Write the parser"),
            budgets: [budget(.claudeCode, used: 90), budget(.codex, used: 20)],
            memory: memory(totalGB: 16, usedGB: 8)))

        XCTAssertEqual(advice.runtime, .codex)
        XCTAssertEqual(advice.confidence, .medium)
    }

    func testEveryRuntimeExhaustedTellsTheUserToWait() {
        let reset = now.addingTimeInterval(3600)
        let advice = DispatchAdvisor.advise(inputs(
            task: task("Write the parser"),
            budgets: [budget(.claudeCode, used: 100, resets: now.addingTimeInterval(7200)),
                      budget(.codex, used: 100, resets: reset)],
            memory: memory(totalGB: 16, usedGB: 8)))

        XCTAssertEqual(advice.verdict, .abstain)
        XCTAssertEqual(advice.waitUntil, reset, "the soonest reset is the useful one")
    }

    // MARK: - The cap is measured, not configured

    /// The same rule, the same expected shape, on two very different machines —
    /// only the measured input changes. This is what makes the cap sellable.
    func testCapScalesWithTheMachineNotWithAConstant() {
        let small = DispatchAdvisor.concurrencyCap(
            memory: memory(totalGB: 16, usedGB: 8, sessions: 2, sessionGB: 2))
        let large = DispatchAdvisor.concurrencyCap(
            memory: memory(totalGB: 64, usedGB: 8, sessions: 2, sessionGB: 2))

        XCTAssertGreaterThan(large.additionalSessions, small.additionalSessions)
        XCTAssertEqual(small.measuredPerSessionBytes, 2_000_000_000)
    }

    /// A user whose sessions are heavier gets a lower cap on identical hardware,
    /// without touching a setting.
    func testHeavierSessionsLowerTheCapOnTheSameMachine() {
        let light = DispatchAdvisor.concurrencyCap(
            memory: memory(totalGB: 64, usedGB: 8, sessions: 2, sessionGB: 1))
        let heavy = DispatchAdvisor.concurrencyCap(
            memory: memory(totalGB: 64, usedGB: 8, sessions: 2, sessionGB: 8))

        XCTAssertGreaterThan(light.additionalSessions, heavy.additionalSessions)
    }

    func testCriticalPressureAllowsNothing() {
        let cap = DispatchAdvisor.concurrencyCap(
            memory: memory(totalGB: 16, usedGB: 14, sessions: 1, sessionGB: 2, pressure: 4))
        XCTAssertEqual(cap.additionalSessions, 0)
    }

    func testWarningPressureAllowsAtMostOne() {
        let cap = DispatchAdvisor.concurrencyCap(
            memory: memory(totalGB: 64, usedGB: 8, sessions: 1, sessionGB: 1, pressure: 2))
        XCTAssertEqual(cap.additionalSessions, 1)
    }

    func testUnmeasuredMachineStaysConservative() {
        let cap = DispatchAdvisor.concurrencyCap(memory: memory(totalGB: 64, usedGB: 8))
        XCTAssertNil(cap.measuredPerSessionBytes)
        XCTAssertTrue(cap.reason.contains("no session observed"))
    }

    // MARK: - Fan-out is a cost decision

    func testResearchFansOutWithinTheSpendCap() {
        let advice = DispatchAdvisor.advise(inputs(
            task: task("Survey the competition", kind: .research),
            budgets: [budget(.claudeCode, used: 5), budget(.codex, used: 80)],
            memory: memory(totalGB: 64, usedGB: 8, sessions: 2, sessionGB: 2),
            spendCap: 3.0, agentCost: 1.0))

        XCTAssertEqual(advice.fanOut, 3)
        XCTAssertEqual(advice.tokenMultiplier, 3)
    }

    /// The multiplier is the number that costs the user money, so it appears
    /// exactly when a fan-out happens and never otherwise.
    func testNoMultiplierIsShownForASingleAgent() {
        let advice = DispatchAdvisor.advise(inputs(
            task: task("Write the parser"),
            budgets: [budget(.claudeCode, used: 5), budget(.codex, used: 80)],
            memory: memory(totalGB: 64, usedGB: 8, sessions: 2, sessionGB: 2),
            spendCap: 10.0, agentCost: 1.0))

        XCTAssertEqual(advice.fanOut, 1)
        XCTAssertNil(advice.tokenMultiplier)
    }

    func testTightSpendCapForcesOneAgentDespiteFreeMemory() {
        let advice = DispatchAdvisor.advise(inputs(
            task: task("Survey the competition", kind: .research),
            budgets: [budget(.claudeCode, used: 5), budget(.codex, used: 80)],
            memory: memory(totalGB: 64, usedGB: 4, sessions: 2, sessionGB: 1),
            spendCap: 1.0, agentCost: 1.0))

        XCTAssertEqual(advice.fanOut, 1)
        XCTAssertNil(advice.tokenMultiplier)
    }

    func testMemoryCapBeatsAGenerousSpendCap() {
        let advice = DispatchAdvisor.advise(inputs(
            task: task("Survey the competition", kind: .research),
            budgets: [budget(.claudeCode, used: 5), budget(.codex, used: 80)],
            memory: memory(totalGB: 16, usedGB: 12, sessions: 2, sessionGB: 2),
            spendCap: 100.0, agentCost: 1.0))

        XCTAssertLessThanOrEqual(advice.fanOut, 1)
    }

    func testBuildTasksNeverFanOut() {
        let advice = DispatchAdvisor.advise(inputs(
            task: task("Implement the parser", kind: .build),
            budgets: [budget(.claudeCode, used: 5), budget(.codex, used: 80)],
            memory: memory(totalGB: 64, usedGB: 4, sessions: 2, sessionGB: 1),
            spendCap: 100.0, agentCost: 1.0))

        XCTAssertEqual(advice.fanOut, 1)
    }
}
