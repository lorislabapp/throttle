@testable import Throttle
import XCTest

/// Tests for the numbers Throttle SHOWS, as opposed to the machinery that
/// produces them.
///
/// The suite had 262 green tests while the app reported savings 116× too high,
/// euro figures 2.3× too high, and a usage cap labelled with the wrong model.
/// Every one of those is a claim made to a person, and not one of them was
/// covered: `StatsDataService`, `PlanAdvisor` and `StatuslineService` had no
/// tests at all. Tests that check the parser parses and the database migrates
/// cannot catch a lie told in a label.
@MainActor
final class DisplayedNumbersTests: XCTestCase {

    // MARK: - The cap belongs to the model Anthropic named

    /// Measured on this account 2026-08-22: the weekly cap sitting at 100% was
    /// scoped to **Fable**, and the app called it "Weekly · Sonnet" because the
    /// value landed in a field with that name and `scope.model.display_name` was
    /// discarded. `seven_day_sonnet` is `null` on current plans, so the label was
    /// never right — it survived a shape Anthropic stopped sending.
    func testScopedWeeklyCarriesTheModelAnthropicNamed() throws {
        let json = Data("""
        {
          "five_hour":  {"utilization": 0,  "resets_at": "2026-08-22T08:29:59.651414+00:00"},
          "seven_day":  {"utilization": 90, "resets_at": "2026-08-25T13:59:59.651436+00:00"},
          "seven_day_sonnet": null,
          "limits": [
            {"kind": "weekly_all", "percent": 90,
             "resets_at": "2026-08-25T13:59:59.651436+00:00"},
            {"kind": "weekly_scoped", "percent": 100, "is_active": true,
             "resets_at": "2026-08-25T13:59:59.651667+00:00",
             "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}}
          ]
        }
        """.utf8)

        let snap = try OAuthUsageProvider.decodeSnapshot(json)

        XCTAssertEqual(snap.sevenDayScoped.utilization, 100)
        XCTAssertEqual(snap.sevenDayScoped.scopedModel, "Fable",
                       "the model name is in the payload; dropping it is what produced the wrong label")
        XCTAssertEqual(MultiCockpitModel.scopedLabel(snap.sevenDayScoped), "Weekly · Fable")
        XCTAssertNotEqual(MultiCockpitModel.scopedLabel(snap.sevenDayScoped), "Weekly · Sonnet")
    }

    /// When Anthropic does not name a model, say so rather than pick one. Naming
    /// a model we were not told about is precisely the defect being fixed.
    func testUnnamedScopeIsNotGivenAModelName() throws {
        let json = Data("""
        {
          "five_hour": {"utilization": 5, "resets_at": null},
          "seven_day": {"utilization": 10, "resets_at": null},
          "limits": [{"kind": "weekly_scoped", "percent": 42, "resets_at": null}]
        }
        """.utf8)

        let snap = try OAuthUsageProvider.decodeSnapshot(json)
        XCTAssertEqual(snap.sevenDayScoped.utilization, 42)
        XCTAssertNil(snap.sevenDayScoped.scopedModel)
        XCTAssertEqual(MultiCockpitModel.scopedLabel(snap.sevenDayScoped), "Weekly · scoped")
    }

    // MARK: - A hook that adds context is not a saving

    /// The session-start router EMITS the memory files it selected. Its recorded
    /// baseline was every file it could have emitted — "without routing you would
    /// have loaded all of them" — a session nobody would ever run. Measured
    /// 2026-08-22: 291 KB claimed per session against 226 bytes actually emitted,
    /// on top of an index Claude Code loads either way. Counting that difference
    /// as a saving inflated the headline figure 116× for the week.
    func testInjectingHookClaimsNoSaving() {
        let router = TokoptSavingsRow(id: nil, timestamp: 0, hook: "session-start-router",
                                      baselineBytes: 300_000, actualBytes: 226)
        XCTAssertTrue(router.isInjection)
        XCTAssertEqual(router.savedBytes, 0,
                       "a hook that spends context must not report the spend as a gain")
        XCTAssertEqual(router.injectedBytes, 226)
    }

    /// A hook that genuinely removes bytes still reports them.
    func testTrimmingHookKeepsItsSaving() {
        let trim = TokoptSavingsRow(id: nil, timestamp: 0, hook: "tokopt-bash",
                                    baselineBytes: 10_000, actualBytes: 6_000)
        XCTAssertFalse(trim.isInjection)
        XCTAssertEqual(trim.savedBytes, 4_000)
        XCTAssertEqual(trim.injectedBytes, 0)
    }

    /// Trimming rewrites the prompt prefix, so the next turn pays the cache WRITE
    /// price (1.25×) on what remains where the untrimmed session would have paid
    /// the READ price (0.1×). The honest figure for the very next turn is the
    /// saving discounted by that penalty; the rest is earned only if the session
    /// runs long enough. CMV measures break-even around 10 turns for tool-heavy
    /// sessions and 40 for conversational ones.
    func testCacheAwareSavingIsNeverLargerThanTheRawSaving() {
        let trim = TokoptSavingsRow(id: nil, timestamp: 0, hook: "tokopt-bash",
                                    baselineBytes: 100_000, actualBytes: 40_000)
        XCTAssertLessThan(trim.cacheAwareSavedBytes, trim.savedBytes)
    }

    /// A trim that leaves a large prefix behind can cost more than it saves on the
    /// next turn. Reporting a positive number there would be the same error as the
    /// router's, one layer down.
    func testCacheAwareSavingFloorsAtZeroRatherThanGoingNegative() {
        let marginal = TokoptSavingsRow(id: nil, timestamp: 0, hook: "tokopt-bash",
                                        baselineBytes: 101_000, actualBytes: 100_000)
        XCTAssertEqual(marginal.cacheAwareSavedBytes, 0)
    }
}
