@testable import Throttle
import XCTest

/// Coming back is the expensive part. These pin the rules that decide what a
/// returning reader is shown first — and, just as importantly, what is never
/// promoted into that position.
final class SessionReentryDigestTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var awaySince: Date { now.addingTimeInterval(-3_600) }

    private func snapshot(
        _ name: String, live: Bool = true, hibernated: Bool = false,
        needsInput: Bool = false, question: String? = nil, askedAgo: TimeInterval? = nil,
        stopIssue: String? = nil, rateLimitedUntil: Date? = nil,
        repeatedTool: String? = nil, repeats: Int = 0,
        activeAgo: TimeInterval = 600, spentEUR: Double? = nil
    ) -> SessionReentrySnapshot {
        SessionReentrySnapshot(
            id: UUID(), name: name, isLive: live, isHibernated: hibernated,
            needsInput: needsInput, latestQuestion: question,
            questionAskedAt: askedAgo.map { now.addingTimeInterval(-$0) },
            stopIssue: stopIssue, rateLimitedUntil: rateLimitedUntil,
            repeatedTool: repeatedTool, repeats: repeats,
            lastActivityAt: now.addingTimeInterval(-activeAgo), spentEUR: spentEUR
        )
    }

    func test_aShortGapIsNotAnAbsence() {
        let recent = now.addingTimeInterval(-SessionReentryService.minimumAbsence + 1)
        XCTAssertNil(SessionReentryService.digest(
            snapshots: [snapshot("A", needsInput: true, question: "Proceed?")],
            awaySince: recent, now: now
        ), "a glance away is not a return")
    }

    func test_onlyWorkThatNeedsAPersonReachesTheTopTier() throws {
        let digest = try XCTUnwrap(SessionReentryService.digest(snapshots: [
            snapshot("Asked", needsInput: true, question: "Overwrite the file?", askedAgo: 1_800),
            snapshot("Refused", stopIssue: "Session stop could not be confirmed."),
            snapshot("Limited", rateLimitedUntil: now.addingTimeInterval(600)),
            snapshot("Looping", repeatedTool: "Bash: npm test", repeats: 9),
            snapshot("Busy", activeAgo: 120),
            snapshot("Idle", activeAgo: 7_200)
        ], awaySince: awaySince, now: now))

        XCTAssertEqual(digest.items(in: .waitingOnYou).map(\.name).sorted(),
                       ["Asked", "Limited", "Refused"])
        XCTAssertEqual(digest.items(in: .moved).map(\.name).sorted(), ["Busy", "Looping"])
        XCTAssertEqual(digest.items(in: .quiet).map(\.name), ["Idle"])
        XCTAssertTrue(digest.isWorthShowing)
    }

    func test_aLoopSuspicionIsOfferedAsAGuessAndNeverAsAnAlarm() throws {
        let below = try XCTUnwrap(SessionReentryService.digest(
            snapshots: [snapshot("A", repeatedTool: "Bash: ls",
                                 repeats: SessionReentryService.loopMentionThreshold - 1)],
            awaySince: awaySince, now: now
        ))
        XCTAssertEqual(below.items.first?.tier, .moved)
        XCTAssertNil(below.items.first?.note, "below the threshold it is not even mentioned as a loop")

        let above = try XCTUnwrap(SessionReentryService.digest(
            snapshots: [snapshot("A", repeatedTool: "Bash: ls", repeats: 12)],
            awaySince: awaySince, now: now
        ))
        let item = try XCTUnwrap(above.items.first)
        XCTAssertEqual(item.tier, .moved, "a heuristic is never something you must resolve")
        XCTAssertEqual(item.note, "a guess worth checking, not a verdict")
        XCTAssertTrue(item.headline.contains("12 times"))
    }

    func test_aLimitThatHasAlreadyLiftedIsHistory() throws {
        let digest = try XCTUnwrap(SessionReentryService.digest(
            snapshots: [snapshot("A", rateLimitedUntil: now.addingTimeInterval(-60), activeAgo: 120)],
            awaySince: awaySince, now: now
        ))
        XCTAssertEqual(digest.items.first?.tier, .moved, "nothing is asked of a person for a limit that lifted")
    }

    func test_theHeadlineNamesOneThingAndTheAbsenceIsReadable() throws {
        let waiting = try XCTUnwrap(SessionReentryService.digest(
            snapshots: [snapshot("A", needsInput: true, question: "Go?"), snapshot("B", activeAgo: 60)],
            awaySince: awaySince, now: now
        ))
        XCTAssertEqual(waiting.headline, "1 session(s) waiting on you after 1h")

        let moved = try XCTUnwrap(SessionReentryService.digest(
            snapshots: [snapshot("B", activeAgo: 60)],
            awaySince: now.addingTimeInterval(-5_400), now: now
        ))
        XCTAssertEqual(moved.headline, "1 session(s) moved on while you were away, 1h30")

        let quiet = try XCTUnwrap(SessionReentryService.digest(
            snapshots: [snapshot("C", activeAgo: 9_000)],
            awaySince: awaySince, now: now
        ))
        XCTAssertEqual(quiet.headline, "Nothing moved in 1h")
        XCTAssertFalse(quiet.isWorthShowing, "a panel with nothing in it should not appear")
        XCTAssertEqual(SessionReentryDigest.duration(30), "under a minute")
        XCTAssertEqual(SessionReentryDigest.duration(59 * 60), "59 min")
    }

    func test_spendWhileAwayIsSummedOnlyFromWhatIsKnown() throws {
        let digest = try XCTUnwrap(SessionReentryService.digest(
            snapshots: [snapshot("A", spentEUR: 1.25), snapshot("B", spentEUR: 0.75), snapshot("C")],
            awaySince: awaySince, now: now
        ))
        XCTAssertEqual(try XCTUnwrap(digest.spentWhileAwayEUR), 2.0, accuracy: 0.0001)
        XCTAssertNil(try XCTUnwrap(SessionReentryService.digest(
            snapshots: [snapshot("C")], awaySince: awaySince, now: now
        )).spentWhileAwayEUR, "an unknown cost is not reported as zero")
    }

    @MainActor
    func test_theQuietLineFoldsRatherThanListing() {
        XCTAssertEqual(MultiCockpitRoot.quietLine([]), "")
        XCTAssertEqual(MultiCockpitRoot.quietLine(["A", "B"]), "Quiet: A, B")
        XCTAssertEqual(MultiCockpitRoot.quietLine(["A", "B", "C", "D", "E"]),
                       "Quiet: A, B, C and 2 more")
        XCTAssertEqual(MultiCockpitRoot.tierTitle(.waitingOnYou), "WAITING ON YOU")
    }

    @MainActor
    func test_anAbsenceStartsOnceAndAPanelAppearsOnlyWhenThereIsSomethingToSay() {
        let model = MultiCockpitModel()
        model.noteAttentionLeft(at: now.addingTimeInterval(-3_600))
        model.noteAttentionLeft(at: now.addingTimeInterval(-60))
        XCTAssertEqual(model.awaySince, now.addingTimeInterval(-3_600),
                       "a second glance away does not restart the absence")

        model.noteAttentionReturned(at: now)
        XCTAssertNil(model.reentryDigest, "no sessions, nothing to report")
        XCTAssertNil(model.awaySince, "returning always clears the absence")

        model.noteAttentionReturned(at: now)
        XCTAssertNil(model.reentryDigest, "returning without having left reports nothing")
    }

    func test_aQuestionIsShownAsTheAgentSaidItButBounded() {
        XCTAssertEqual(SessionReentryService.oneLine("  Do you want\n\n  me to continue?  "),
                       "Do you want me to continue?")
        let long = String(repeating: "a", count: 200)
        let bounded = SessionReentryService.oneLine(long)
        XCTAssertEqual(bounded.count, 141)
        XCTAssertTrue(bounded.hasSuffix("…"))
        XCTAssertEqual(SessionReentryService.oneLine(""), "")
    }
}
