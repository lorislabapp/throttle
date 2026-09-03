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

    // MARK: - The scoped cap keeps its name everywhere, not just in the cockpit

    /// The cockpit label was fixed and the menu bar was not: `DropdownView`
    /// hardcoded the string "Sonnet only", so the screenshot still read
    /// "Weekly · Sonnet only" over a cap scoped to Fable. Worse, the OFFLINE
    /// estimate behind that row filtered `LIKE '%sonnet%'`, so it counted a
    /// different model's events than the cap it claimed to track.
    func testScopedCapNamesAndFiltersTheModelTheServerStated() {
        let saved = ScopedCapModel.displayName
        // The labels now also depend on whether the token was found in the
        // database, and that flag lives in the same real preferences domain.
        // Pin it, or a previous app run decides this test.
        let savedUnmatched = ScopedCapModel.tokenMatchedNothing
        defer {
            ScopedCapModel.displayName = saved
            ScopedCapModel.tokenMatchedNothing = savedUnmatched
        }
        ScopedCapModel.tokenMatchedNothing = false

        ScopedCapModel.displayName = nil
        XCTAssertEqual(ScopedCapModel.subtitle, "Sonnet only",
                       "before the server states a model, say what is actually measured")
        XCTAssertEqual(ScopedCapModel.match, .family(.sonnet))

        ScopedCapModel.remember("Fable")
        XCTAssertEqual(ScopedCapModel.subtitle, "Fable only")
        XCTAssertEqual(ScopedCapModel.bindingLabel, "Weekly · Fable")
        XCTAssertEqual(ScopedCapModel.match, .family(.fable),
                       "the local estimate must count the capped model, not Sonnet")
        // Resolved to a family, not to the literal word: the name is prose and
        // the column holds ids, so "Fable" must also reach `claude-mythos-*`.
        XCTAssertEqual(ScopedCapModel.match(forDisplayName: "Mythos"), .family(.fable))
        XCTAssertEqual(ScopedCapModel.match(forDisplayName: "Claude Opus 4.7"), .family(.opus))
        XCTAssertEqual(MultiCockpitModel.scopedLabelMirror, "Weekly · Fable")

        // A name whose token found no event is not the model being measured, so
        // the row must stop wearing it — keeping a name it is not counting is
        // exactly what started this.
        ScopedCapModel.tokenMatchedNothing = true
        XCTAssertEqual(ScopedCapModel.subtitle, "Sonnet only (default)")
        XCTAssertEqual(ScopedCapModel.bindingLabel, "Weekly · Sonnet")
    }

    /// A payload that omits the scope must not erase a name we were already
    /// given — otherwise one incomplete poll reverts every label to Sonnet.
    func testAbsentScopeDoesNotUnlearnTheModel() {
        let saved = ScopedCapModel.displayName
        defer { ScopedCapModel.displayName = saved }

        ScopedCapModel.remember("Fable")
        ScopedCapModel.remember(nil)
        ScopedCapModel.remember("")
        XCTAssertEqual(ScopedCapModel.displayName, "Fable")
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

    // MARK: - One pressure doctrine, not three

    /// The menu bar excluded the per-model weekly cap from the headline (it
    /// forces a model fallback, it does not lock you out) and the statusline
    /// included it, under a comment promising they used the same rule. Measured
    /// 2026-08-22: the scoped cap sat at 100%, so every terminal on this Mac
    /// showed a red 100% while the menu bar showed the truth.
    func testScopedCapNeverBecomesTheHeadlinePressure() {
        let exact = ExactSnapshot(
            fiveHour: .init(utilization: 12, resetsAt: nil),
            sevenDay: .init(utilization: 40, resetsAt: nil),
            sevenDayScoped: .init(utilization: 100, resetsAt: nil, scopedModel: "Fable"),
            fetchedAt: Date())

        let reading = UsagePressure.binding(snapshot: .empty, exact: exact, codex: nil)
        XCTAssertEqual(reading?.percent, 40,
                       "the all-models week binds; the scoped cap at 100% must not")
        XCTAssertNotEqual(reading?.percent, 100)
    }

    /// Codex counts toward pressure. The menu bar included it, the statusline
    /// did not — the same disagreement in the other direction.
    func testCodexPressureCountsToo() {
        let exact = ExactSnapshot(
            fiveHour: .init(utilization: 10, resetsAt: nil),
            sevenDay: .init(utilization: 20, resetsAt: nil),
            sevenDayScoped: .init(utilization: 0, resetsAt: nil),
            fetchedAt: Date())
        let codex = CodexUsageSnapshot(
            sessionID: nil, tokens: nil, contextWindow: nil,
            primary: .init(kind: .primary, usedPercent: 90, windowMinutes: 300, resetsAt: nil),
            secondary: nil, planType: nil, observedAt: Date())

        let reading = UsagePressure.binding(snapshot: .empty, exact: exact, codex: codex)
        XCTAssertEqual(reading?.percent, 90)
    }

    // MARK: - The portfolio graph must stop computing

    /// `TimelineView(.animation(minimumInterval: 1/60))` drove an O(n²)
    /// force-directed step for as long as the cockpit stayed open. Measured on
    /// this Mac 2026-08-22: ~28% of a core, steady, 46 minutes in, with zero
    /// SwiftTerm frames in the profile — the terminals were innocent, the idle
    /// graph was not.
    func testPortfolioLayoutSettlesAndStopsStepping() {
        let sim = PortfolioSim()
        sim.ensure(size: CGSize(width: 600, height: 400))
        sim.seed(PortfolioGraph(
            nodes: (0..<8).map { PortfolioNode(id: "n\($0)", label: "n\($0)", kind: .app, reach: 1) },
            edges: [PortfolioEdge(from: "n0", to: "n1")]))
        sim.ensure(size: CGSize(width: 600, height: 400))

        XCTAssertFalse(sim.settled, "a freshly seeded graph has work to do")
        for _ in 0..<4000 where !sim.settled { sim.step() }
        XCTAssertTrue(sim.settled, "the layout must reach rest and stop asking for frames")

        // And a resize must wake it back up — a settled flag that never clears
        // would leave the graph frozen in the wrong shape.
        sim.ensure(size: CGSize(width: 900, height: 500))
        XCTAssertFalse(sim.settled)
    }

    // MARK: - One price table

    /// Six copies of the rates existed; one still carried Claude 3 Opus prices
    /// ($15/$75) for Opus 5, and Fable matched no branch at all.
    func testPricesAndMultipliersComeFromOneTable() {
        XCTAssertEqual(ModelPricing.rate(forModel: "claude-opus-5").input, 5)
        XCTAssertEqual(ModelPricing.rate(forModel: "claude-fable-5").output, 50)
        XCTAssertEqual(ModelPricing.rate(forModel: "something-unheard-of").input,
                       ModelPricing.sonnet.input, "unknown models price as Sonnet")
        XCTAssertEqual(ModelPricing.priceMultiplier(forBucket: "fable"), 3.33)
        XCTAssertEqual(ModelPricing.priceMultiplier(forBucket: "opus"), 1.67)
        XCTAssertEqual(ModelPricing.priceMultiplier(forBucket: "haiku"), 0.33)
        // The generated SQL must carry the same numbers as the Swift table.
        XCTAssertTrue(ModelPricing.sqlRowEurExpr().contains("output_tokens/1e6*50.0"))
        XCTAssertFalse(ModelPricing.sqlRowEurExpr().contains("*75"), "Claude 3 Opus pricing must be gone")
    }

    /// Fable existed in the SQL bucket expression but not in the Swift enum the
    /// Stats UI reads, so every Fable event arrived as `.other` and was priced
    /// at the Sonnet rate — understated 3.3× on an account where Fable is the
    /// second-largest tier by input tokens.
    func testFableIsATierAndNotOther() {
        XCTAssertEqual(ModelTier.from(modelString: "claude-fable-5"), .fable)
        XCTAssertEqual(ModelTier.from(modelString: "mythos-5"), .fable)
        XCTAssertEqual(ModelTier.from(modelString: "claude-opus-5"), .opus)
        XCTAssertEqual(ModelTier.from(modelString: "who-knows"), .other)
        // The enum and the SQL CASE must agree on every bucket name.
        for tier in ModelTier.allCases where tier != .other {
            XCTAssertEqual(ModelPricing.bucket(forModel: "claude-\(tier.rawValue)-1"), tier.rawValue)
        }
    }

    /// `PlanAdvisor` kept a second rate table converted at 0.92 while
    /// `ModelPricing.usdToEur` is 0.93, and had no Fable branch at all.
    func testPlanAdvisorDerivesItsRatesFromTheOneTable() {
        XCTAssertEqual(PlanAdvisor.opus.inputPerM,
                       ModelPricing.opus.input * ModelPricing.usdToEur, accuracy: 0.0001)
        XCTAssertEqual(PlanAdvisor.fable.outputPerM,
                       ModelPricing.fable.output * ModelPricing.usdToEur, accuracy: 0.0001)
        XCTAssertGreaterThan(PlanAdvisor.fable.inputPerM, PlanAdvisor.opus.inputPerM,
                             "Fable bills more per token than Opus")
    }

    // MARK: - The "vs API" figure prices every family at its own rate

    /// Published USD/M — opus 5/25, sonnet 3/15, fable 10/50 — converted at
    /// 0.93 and weighted 70% input / 30% output. Spelled out so the expected
    /// number is arithmetic a reader can check, not a value copied out of the
    /// implementation.
    private var opusEURPerM: Double { 0.70 * 5 * 0.93 + 0.30 * 25 * 0.93 }    // 10.230
    private var sonnetEURPerM: Double { 0.70 * 3 * 0.93 + 0.30 * 15 * 0.93 }  //  6.138
    private var fableEURPerM: Double { 0.70 * 10 * 0.93 + 0.30 * 50 * 0.93 }  // 20.460

    /// The advisor blended Opus against Sonnet on one fraction, so every family
    /// that was neither — Fable above all — was priced at the Sonnet rate. This
    /// is the "vs API" figure the plan decision is made on.
    func testAPIEquivalentPricesAThreeFamilyMixAtEachFamilysOwnRate() {
        // 10M weighted tokens/wk, split 50% Opus / 30% Sonnet / 20% Fable.
        let weekly = 10_000_000
        let mix: [ModelTier: Int] = [.opus: 5_000_000, .sonnet: 3_000_000, .fable: 2_000_000]

        let blendedPerM = 0.5 * opusEURPerM + 0.3 * sonnetEURPerM + 0.2 * fableEURPerM
        XCTAssertEqual(blendedPerM, 11.0484, accuracy: 0.0001)

        let expected = Double(weekly) * 4.33 / 1_000_000 * blendedPerM  // ≈ 478.40
        XCTAssertEqual(expected, 478.3957, accuracy: 0.001)

        let verdict = PlanAdvisor.recommend(weeklyWeightedTokens: weekly, mix: mix)
        XCTAssertEqual(verdict.apiEquivalentMonthlyEUR, expected, accuracy: 0.01)

        // What the old two-family blend produced for the same usage: Fable
        // charged at the Sonnet rate. It must be materially lower, and it is
        // the direction that matters — it made paying per token look cheaper.
        let oldWay = Double(weekly) * 4.33 / 1_000_000
            * (0.5 * opusEURPerM + 0.5 * sonnetEURPerM)
        XCTAssertLessThan(oldWay, verdict.apiEquivalentMonthlyEUR)
        // 43.3 Mtok/mo × (11.0484 − 8.1840) €/M = €124.03/mo of hidden burn.
        XCTAssertEqual(verdict.apiEquivalentMonthlyEUR - oldWay, 124.03, accuracy: 0.05,
                       "Fable priced as Sonnet understated this mix by ~€124/mo")
    }

    /// A family with no published rate is reachable, and what it does is a
    /// decision rather than an accident: it takes `ModelPricing.unknown`, which
    /// is the Sonnet rate, so an unrecognised (usually newer, dearer) model
    /// understates the API figure and errs against the subscription.
    func testUnratedFamilyIsPricedAsUnknownAndNotRoundedUp() {
        XCTAssertEqual(PlanAdvisor.weightedEURPerM(for: .other),
                       PlanAdvisor.weightedEURPerM(for: .sonnet), accuracy: 0.0001)
        XCTAssertLessThan(PlanAdvisor.weightedEURPerM(for: .other),
                          PlanAdvisor.weightedEURPerM(for: .fable),
                          "an unknown family must not be rounded up to flatter the plan")
        XCTAssertEqual(PlanAdvisor.weightedEURPerM(for: .fable), fableEURPerM, accuracy: 0.0001)
    }

    /// No split to offer must keep producing the number it always produced.
    func testEmptyMixKeepsTheDocumentedThirtySeventyGuess() {
        let expected = 0.30 * opusEURPerM + 0.70 * sonnetEURPerM
        XCTAssertEqual(PlanAdvisor.apiRateEURPerM(mix: [:]), expected, accuracy: 0.0001)
        XCTAssertEqual(PlanAdvisor.apiRateEURPerM(mix: [.opus: 0, .sonnet: 0]),
                       expected, accuracy: 0.0001)
        XCTAssertEqual(PlanAdvisor.apiRateEURPerM(mix: [.fable: -5]),
                       expected, accuracy: 0.0001, "a negative count must not subtract")
    }

    /// Pins the wiring the view used to hide: the split's per-tier counts must
    /// reach `recommend`. While `computeMix` was private to a `View`, a
    /// regression to an empty mix would have printed the 30/70 guess in the same
    /// row and typeface as a measurement, with the suite green.
    func testTheModelSplitReachesTheAdvisorRatherThanTheGuess() {
        let slices = [
            StatsDataService.ModelSlice(tier: .opus, weightedTokens: 5_000_000),
            StatsDataService.ModelSlice(tier: .sonnet, weightedTokens: 3_000_000),
            StatsDataService.ModelSlice(tier: .fable, weightedTokens: 2_000_000)
        ]
        let mix = PlanAdvisor.mix(from: slices)
        XCTAssertEqual(mix, [.opus: 5_000_000, .sonnet: 3_000_000, .fable: 2_000_000])

        let measured = PlanAdvisor.recommend(weeklyWeightedTokens: 10_000_000, mix: mix)
        let guessed = PlanAdvisor.recommend(weeklyWeightedTokens: 10_000_000, mix: [:])
        XCTAssertNotEqual(measured.apiEquivalentMonthlyEUR, guessed.apiEquivalentMonthlyEUR,
                          "a measured split must not land on the guess's number")
        XCTAssertEqual(measured.apiBasis, .boundedByMeasuredMix)
        XCTAssertEqual(guessed.apiBasis, .assumedMix)
    }

    /// The badge must not outrun the figure. "UPPER BOUND" was unconditional
    /// while the same file documented the unrated path as understating; both
    /// could not be true, and the doc is the one that was right.
    func testAPIBasisDistinguishesAMeasurementFromAGuessAndFromAnUnratedMix() {
        XCTAssertEqual(PlanAdvisor.apiBasis(for: [:]), .assumedMix)
        XCTAssertEqual(PlanAdvisor.apiBasis(for: [.opus: 0]), .assumedMix)
        XCTAssertEqual(PlanAdvisor.apiBasis(for: [.opus: 10, .sonnet: 5]), .boundedByMeasuredMix)
        XCTAssertEqual(PlanAdvisor.apiBasis(for: [.opus: 10, .other: 1]),
                       .measuredMixWithUnratedFamily,
                       "unrated tokens are priced as Sonnet, so the figure can understate")
        XCTAssertEqual(PlanAdvisor.apiBasis(for: [.opus: 10, .other: 0]), .boundedByMeasuredMix)
    }

    // MARK: - An empty exclusion set must not break the SQL

    func testInjectingHookPredicateIsAlwaysValidSQL() {
        XCTAssertTrue(TokoptSavingsRow.notInjectingSQL.contains("session-start-router"))
        XCTAssertTrue(TokoptSavingsRow.notInjectingSQL.hasPrefix("hook NOT IN ("))
    }

    // MARK: - The indexer must not embed somebody else's library

    /// Exact-name matching let a Python virtualenv into the semantic index: the
    /// directory was `venv312` and its sibling `.venv312-preserve`, so neither
    /// matched `venv` nor `.venv`. Measured 2026-08-22, that one repository held
    /// 1.8 GB of the 3.0 GB the index occupied — torch, scipy and sympy embedded
    /// as if they were the user's code, on a Mac whose disk hit zero twice that
    /// day.
    func testIndexerPrunesVirtualenvsWhateverTheyAreCalled() {
        for name in ["venv", ".venv", "venv312", ".venv312-preserve", "virtualenv", "env-3.12", ".tox"] {
            XCTAssertTrue(RepoIndexer.isExcluded(directoryNamed: name), "\(name) should be pruned")
        }
        XCTAssertTrue(RepoIndexer.isExcluded(directoryNamed: "site-packages"))
        XCTAssertTrue(RepoIndexer.isExcluded(directoryNamed: "node_modules"))
    }

    /// Source directories whose names merely start with the same letters must
    /// survive — a prefix rule that eats real code is worse than the leak.
    func testIndexerKeepsSourceDirectoriesThatLookAlike() {
        for name in ["Environment", "Views", "envelope", "Services", "Endpoints"] {
            XCTAssertFalse(RepoIndexer.isExcluded(directoryNamed: name), "\(name) is source, keep it")
        }
    }
}
