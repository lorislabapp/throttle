@testable import Throttle
import XCTest

/// The at-cap menu-bar countdown must stay compact (the menu bar is precious
/// real estate) and never show a negative time when a stale snapshot still
/// reports 100% after the window actually reset.
final class MenuBarCountdownTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_755_600_000)

    func testUnderAMinuteClampsToNow() {
        XCTAssertEqual(MenuBarLabel.countdown(to: now.addingTimeInterval(30), now: now), "now")
        XCTAssertEqual(MenuBarLabel.countdown(to: now.addingTimeInterval(-3600), now: now), "now")
    }

    func testMinutes() {
        XCTAssertEqual(MenuBarLabel.countdown(to: now.addingTimeInterval(47 * 60), now: now), "47m")
        XCTAssertEqual(MenuBarLabel.countdown(to: now.addingTimeInterval(59 * 60 + 59), now: now), "59m")
    }

    func testHoursCarryMinutes() {
        XCTAssertEqual(MenuBarLabel.countdown(to: now.addingTimeInterval(2 * 3600 + 5 * 60), now: now), "2h05")
        XCTAssertEqual(MenuBarLabel.countdown(to: now.addingTimeInterval(23 * 3600 + 59 * 60), now: now), "23h59")
    }

    func testDays() {
        XCTAssertEqual(MenuBarLabel.countdown(to: now.addingTimeInterval(3 * 86_400 + 3600), now: now), "3d")
    }
}
