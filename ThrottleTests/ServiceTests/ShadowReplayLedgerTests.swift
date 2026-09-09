@testable import Throttle
import XCTest

/// The numbers a published bound rests on, derived here rather than trusted:
/// exploratory cases never certify, un-adjudicated cases carry no evidence, a
/// single overturned `verified` turns a bound into a measured rate.
final class ShadowReplayLedgerTests: XCTestCase {
    private func entry(_ index: Int, status: String = "verified", stage: ShadowReplayService.Stage? = .certification,
                       adjudicated: String? = "verified", source: String? = "src") -> ShadowReplayService.Entry {
        var entry = ShadowReplayService.Entry(ts: Int64(1_800_000_000 + index), sessionId: "s\(index)", project: "p",
                                              kind: "build", status: status, reason: "r", frontierWeightedTokens: 1,
                                              frontierEUR: 0, latencyMs: 1, askCharacters: 1, localCharacters: 1)
        entry.stage = stage?.rawValue
        entry.adjudicatedStatus = adjudicated
        entry.sourceSHA256 = source
        return entry
    }

    func test_casesNeededIsDerivedFromTheExactBinomialBound() {
        XCTAssertEqual(ShadowReplayService.Ledger.casesNeeded(forBound: 0.01), 299)
        XCTAssertEqual(ShadowReplayService.Ledger.casesNeeded(forBound: 0.03), 99)
        XCTAssertEqual(ShadowReplayService.Ledger.casesNeeded(forBound: 0.005), 598)
        XCTAssertEqual(ShadowReplayService.Ledger.casesNeeded(forBound: 0), .max)
        XCTAssertEqual(ShadowReplayService.Ledger.casesNeeded(forBound: 0.01, confidence: 1), .max)
    }

    func test_onlyAdjudicatedCertificationClaimsBoundTheFalseVerifiedRate() throws {
        var entries = (0 ..< 10).map { entry($0) }
        entries.append(entry(10, stage: .exploratory))
        entries.append(entry(11, adjudicated: nil))
        entries.append(entry(12, status: "review_required", adjudicated: "review_required"))
        let ledger = ShadowReplayService.Ledger(entries: entries)
        XCTAssertEqual(ledger.certified.count, 11, "exploratory and un-adjudicated cases are not evidence")
        XCTAssertEqual(ledger.certifiedVerifiedClaims, 10)
        XCTAssertEqual(ledger.falseVerified, 0)
        let bound = try XCTUnwrap(ledger.falseVerifiedBound95)
        XCTAssertEqual(bound, 1 - pow(0.05, 0.1), accuracy: 1e-12)
        XCTAssertNil(ShadowReplayService.Ledger(entries: Array(entries.prefix(9))).falseVerifiedBound95,
                     "below ten claims the bound is too weak to quote")
    }

    func test_oneOverturnedVerifiedTurnsTheBoundIntoAMeasuredRate() {
        var entries = (0 ..< 20).map { entry($0) }
        entries[3] = entry(3, adjudicated: "escalate")
        let ledger = ShadowReplayService.Ledger(entries: entries)
        XCTAssertEqual(ledger.falseVerified, 1)
        XCTAssertNil(ledger.falseVerifiedBound95)
        XCTAssertTrue(entries[3].isFalseVerified)
        XCTAssertFalse(entry(0, status: "review_required", adjudicated: "escalate").isFalseVerified,
                       "a refusal the human sharpened is the contract working, not a false verified")
    }

    func test_hardFailureBoundIsSecondaryAndVanishesOnAnyHardFailure() throws {
        let clean = ShadowReplayService.Ledger(entries: (0 ..< 12).map { entry($0) })
        XCTAssertEqual(try XCTUnwrap(clean.hardFailureBound95), 1 - pow(0.05, 1.0 / 12), accuracy: 1e-12)
        var entries = (0 ..< 12).map { entry($0) }
        entries[0] = entry(0, status: "escalate", adjudicated: nil)
        XCTAssertNil(ShadowReplayService.Ledger(entries: entries).hardFailureBound95)
        XCTAssertNil(ShadowReplayService.Ledger(entries: Array(entries.prefix(5))).hardFailureBound95)
    }

    func test_theFrozenCertificationSetHasAStableIdentity() throws {
        let frozen = ShadowReplayService.Ledger(entries: [entry(0), entry(1), entry(2, stage: .exploratory)])
        let reordered = ShadowReplayService.Ledger(entries: [entry(1), entry(2, stage: .exploratory), entry(0)])
        XCTAssertEqual(frozen.certificationCaseSetSHA256?.count, 64)
        XCTAssertEqual(frozen.certificationCaseSetSHA256, reordered.certificationCaseSetSHA256)
        let grown = ShadowReplayService.Ledger(entries: [entry(0), entry(1), entry(3)])
        let resourced = ShadowReplayService.Ledger(entries: [entry(0), entry(1, source: "other")])
        XCTAssertNotEqual(frozen.certificationCaseSetSHA256, grown.certificationCaseSetSHA256)
        XCTAssertNotEqual(frozen.certificationCaseSetSHA256, resourced.certificationCaseSetSHA256,
                          "a case re-run against a different source is a different frozen set")
        XCTAssertNil(ShadowReplayService.Ledger(entries: [entry(0, stage: .exploratory)]).certificationCaseSetSHA256)
        XCTAssertNil(ShadowReplayService.Ledger.empty.certificationCaseSetSHA256)
    }
}
