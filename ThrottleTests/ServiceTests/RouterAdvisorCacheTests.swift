@testable import Throttle
import XCTest

/// Caches are model-scoped: a detour to another model does not read the context
/// already paid for, and coming back rebuilds it at the write rate. The advisor
/// must therefore route between sessions, never inside one — and say what a
/// detour would cost rather than leaving the reader to discover it on the bill.
final class RouterAdvisorCacheTests: XCTestCase {
    private let empty = ShadowReplayService.Ledger.empty
    private let boundedAsk = "summarize the release notes for this build"

    private func cache(_ tokens: Int, model: String = "claude-sonnet-5") -> PromptCacheImpact? {
        PromptCacheImpactService.estimate(contextTokens: tokens, model: model)
    }

    func test_atASessionBoundaryABoundedAskIsStillLocal() {
        let advice = RouterAdvisorService.advise(objective: boundedAsk, ledger: empty, session: nil)
        XCTAssertEqual(advice.recommendation, .local)
        XCTAssertNil(advice.detour, "no session, nothing to strand")
    }

    func test_insideAWarmSessionTheSameAskGoesFrontierAndSaysWhatItWouldCost() throws {
        let session = try XCTUnwrap(cache(60_000))
        let advice = RouterAdvisorService.advise(objective: boundedAsk, ledger: empty, session: session)
        XCTAssertEqual(advice.recommendation, .frontier)
        let detour = try XCTUnwrap(advice.detour)
        XCTAssertEqual(detour.contextTokens, 60_000)
        XCTAssertEqual(detour.strandedEUR, session.rebuildEUR)
        XCTAssertTrue(detour.line.contains("60k"), detour.line)
        XCTAssertEqual(advice.reasons.first, detour.line + " — route between sessions, not inside one")
    }

    func test_aColdOrTinySessionDoesNotOverrideTheJudgement() throws {
        let tiny = try XCTUnwrap(cache(RouterAdvisorService.sessionAffinityFloor - 1))
        let advice = RouterAdvisorService.advise(objective: boundedAsk, ledger: empty, session: tiny)
        XCTAssertEqual(advice.recommendation, .local, "context this small is cheaper to rebuild than to protect")
        XCTAssertNil(advice.detour)
    }

    func test_affinityOnlyEverMovesAdviceTowardsFrontier() throws {
        let session = try XCTUnwrap(cache(80_000))
        let critical = RouterAdvisorService.advise(
            objective: "rotate the signing credential before the release", ledger: empty, session: session
        )
        XCTAssertEqual(critical.recommendation, .frontier)
        XCTAssertNotNil(critical.detour, "the cost is reported even when the verdict was already frontier")
        XCTAssertFalse(critical.reasons.contains { $0.contains("route between sessions") },
                       "a verdict that was never local is not re-explained as affinity")

        let uncertain = RouterAdvisorService.applyingSessionAffinity(
            RouterAdvisorService.Advice(recommendation: .uncertain, reasons: ["vague"]), session: session
        )
        XCTAssertEqual(uncertain.recommendation, .uncertain, "affinity never promotes and never demotes past frontier")
        XCTAssertNotNil(uncertain.detour)
    }

    func test_theStrandedPriceFollowsTheModelTheSessionActuallyUses() throws {
        let sonnet = try XCTUnwrap(cache(50_000, model: "claude-sonnet-5"))
        let fable = try XCTUnwrap(cache(50_000, model: "claude-fable-5-1"))
        XCTAssertGreaterThan(fable.rebuildEUR, sonnet.rebuildEUR,
                             "the same context strands more on a dearer model")
        let advice = RouterAdvisorService.advise(objective: boundedAsk, ledger: empty, session: fable)
        XCTAssertEqual(advice.detour?.strandedEUR, fable.rebuildEUR)
    }
}
