import XCTest
@testable import Throttle

/// A freeze carries WHY it happened, because two policies hang off it: does
/// focusing the tab undo it, and may memory pressure escalate it to a hibernate.
///
/// The regression this guards: those policies used to hang off a loose
/// `autoPaused` bool that only ONE of the automatic pause paths set. A tab frozen
/// by the pacing one-tap or the ≥95% breaker was therefore indistinguishable from
/// a tab the user paused by hand — it stayed frozen when focused, showing a stalled
/// spinner and dead scroll, which reads as a broken terminal.
final class PauseReasonTests: XCTestCase {

    /// Focus undoes only the freezes Throttle applied as a resource guess FOR the
    /// user. Focusing is them saying the guess was wrong; it costs no tokens.
    func testFocusWakesOnlyResourceDrivenFreezes() {
        XCTAssertTrue(CockpitTab.PauseReason.crowding.resumesOnFocus)
        XCTAssertTrue(CockpitTab.PauseReason.pacing.resumesOnFocus)
    }

    /// Deliberate freezes survive focus. Waking the breaker the moment you look at
    /// the tab would defeat the breaker; waking a hand-paused tab overrides explicit
    /// intent; waking a rule-paused tab skips the check the rule exists to force.
    func testDeliberateFreezesSurviveFocus() {
        XCTAssertFalse(CockpitTab.PauseReason.user.resumesOnFocus)
        XCTAssertFalse(CockpitTab.PauseReason.capBreaker.resumesOnFocus)
        XCTAssertFalse(CockpitTab.PauseReason.rule("cap").resumesOnFocus)
    }

    /// Escalation kills the subtree and makes the wake cost `--resume` tokens. Only
    /// ever applied to a freeze we chose ourselves for resource reasons.
    func testOnlyResourceFreezesEscalateToHibernate() {
        XCTAssertTrue(CockpitTab.PauseReason.crowding.escalatesToHibernate)
        XCTAssertTrue(CockpitTab.PauseReason.pacing.escalatesToHibernate)
        XCTAssertFalse(CockpitTab.PauseReason.user.escalatesToHibernate)
        XCTAssertFalse(CockpitTab.PauseReason.capBreaker.escalatesToHibernate)
        XCTAssertFalse(CockpitTab.PauseReason.rule("cap").escalatesToHibernate)
    }

    /// Every reason can explain itself over the pane. An unexplained freeze is the
    /// bug: the terminal keeps its last frame and looks merely broken.
    func testEveryReasonExplainsItself() {
        let all: [CockpitTab.PauseReason] = [.user, .crowding, .pacing, .capBreaker, .rule("Opus crossed the cap.")]
        for reason in all {
            XCTAssertFalse(reason.title.isEmpty, "\(reason) has no title")
            XCTAssertFalse(reason.detail.isEmpty, "\(reason) has no detail")
        }
    }

    /// A fresh tab is running, not frozen.
    @MainActor func testUnpausedTabHasNoReason() {
        let tab = CockpitTab(projectName: "T", cwd: NSTemporaryDirectory(), runtime: .claudeCode,
                             missionID: UUID(), resumeSessionId: nil)
        XCTAssertNil(tab.pauseReason)
        XCTAssertFalse(tab.isPaused)
    }
}
