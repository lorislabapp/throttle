@testable import Throttle
import XCTest

/// The at-cap menu-bar countdown must stay compact (the menu bar is precious
/// real estate) and never show a negative time when a stale snapshot still
/// reports 100% after the window actually reset.
final class MenuBarCountdownTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_755_600_000)

    func testUnderAMinuteClampsToNow() async {
        let future = await MenuBarLabel.countdown(to: now.addingTimeInterval(30), now: now)
        let stale = await MenuBarLabel.countdown(to: now.addingTimeInterval(-3600), now: now)
        XCTAssertEqual(future, "now")
        XCTAssertEqual(stale, "now")
    }

    func testMinutes() async {
        let fortySeven = await MenuBarLabel.countdown(
            to: now.addingTimeInterval(47 * 60),
            now: now
        )
        let fiftyNine = await MenuBarLabel.countdown(
            to: now.addingTimeInterval(59 * 60 + 59),
            now: now
        )
        XCTAssertEqual(fortySeven, "47m")
        XCTAssertEqual(fiftyNine, "59m")
    }

    func testHoursCarryMinutes() async {
        let twoHours = await MenuBarLabel.countdown(
            to: now.addingTimeInterval(2 * 3600 + 5 * 60),
            now: now
        )
        let twentyThreeHours = await MenuBarLabel.countdown(
            to: now.addingTimeInterval(23 * 3600 + 59 * 60),
            now: now
        )
        XCTAssertEqual(twoHours, "2h05")
        XCTAssertEqual(twentyThreeHours, "23h59")
    }

    func testDays() async {
        let threeDays = await MenuBarLabel.countdown(
            to: now.addingTimeInterval(3 * 86_400 + 3600),
            now: now
        )
        XCTAssertEqual(threeDays, "3d")
    }
}
