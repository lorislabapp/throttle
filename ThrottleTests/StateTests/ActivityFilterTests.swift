@testable import Throttle
import XCTest

/// The rail / tab-bar activity filter has two tiers the user must be able to
/// tell apart: LIVE (a process is running, even if it sits at the prompt) and
/// ACTIVE (it is doing something, or waiting on the user, right now).
///
/// `isActive` deliberately uses a 60 s window, not the 6 s that drives the
/// state dot: a filter that drops a tab six seconds after its last byte makes
/// the list flicker while an agent thinks between tool calls.
@MainActor
final class ActivityFilterTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: isActive (pure, no PTY)

    func testWaitingOnUserIsActive() {
        XCTAssertTrue(CockpitTab.isActive(needsInput: true, rateLimited: false,
                                          lastActivityAt: now.addingTimeInterval(-3600), now: now))
    }

    func testRateLimitedIsActive() {
        XCTAssertTrue(CockpitTab.isActive(needsInput: false, rateLimited: true,
                                          lastActivityAt: now.addingTimeInterval(-3600), now: now))
    }

    func testRecentOutputWithinHysteresisIsActive() {
        XCTAssertTrue(CockpitTab.isActive(needsInput: false, rateLimited: false,
                                          lastActivityAt: now.addingTimeInterval(-59), now: now))
    }

    func testQuietBeyondHysteresisIsIdleNotActive() {
        XCTAssertFalse(CockpitTab.isActive(needsInput: false, rateLimited: false,
                                           lastActivityAt: now.addingTimeInterval(-61), now: now))
    }

    // MARK: filter predicate

    func testAllPassesEverything() {
        XCTAssertTrue(MultiCockpitModel.ActivityFilter.all.passes(isLive: false, isActive: false))
    }

    func testLiveRequiresARunningProcess() {
        XCTAssertTrue(MultiCockpitModel.ActivityFilter.live.passes(isLive: true, isActive: false))
        XCTAssertFalse(MultiCockpitModel.ActivityFilter.live.passes(isLive: false, isActive: false))
    }

    func testActiveRequiresActivity() {
        XCTAssertTrue(MultiCockpitModel.ActivityFilter.active.passes(isLive: true, isActive: true))
        XCTAssertFalse(MultiCockpitModel.ActivityFilter.active.passes(isLive: true, isActive: false))
    }

    // MARK: visible list

    /// An unspawned tab is dormant, so it never passes LIVE. But the SELECTED
    /// tab is what the terminal shows — hiding it from the list would show a
    /// session the rail claims doesn't exist.
    func testSelectedTabStaysVisibleEvenWhenFilteredOut() {
        let tabA = CockpitTab(projectName: "a", cwd: "/tmp/a")
        let tabB = CockpitTab(projectName: "b", cwd: "/tmp/b")
        let visible = MultiCockpitModel.visibleSessions([tabA, tabB], visibleIDs: [], pinned: tabB.id)
        XCTAssertEqual(visible.map(\.id), [tabB.id])
    }

    func testNilVisibleSetMeansNoFiltering() {
        let tabA = CockpitTab(projectName: "a", cwd: "/tmp/a")
        let tabB = CockpitTab(projectName: "b", cwd: "/tmp/b")
        let visible = MultiCockpitModel.visibleSessions([tabA, tabB], visibleIDs: nil, pinned: nil)
        XCTAssertEqual(visible.map(\.id), [tabA.id, tabB.id])
    }

    func testVisibleSetKeepsDisplayOrder() {
        let tabA = CockpitTab(projectName: "a", cwd: "/tmp/a")
        let tabB = CockpitTab(projectName: "b", cwd: "/tmp/b")
        let tabC = CockpitTab(projectName: "c", cwd: "/tmp/c")
        let visible = MultiCockpitModel.visibleSessions([tabC, tabB, tabA], visibleIDs: [tabA.id, tabC.id], pinned: nil)
        XCTAssertEqual(visible.map(\.id), [tabC.id, tabA.id])
    }
}
