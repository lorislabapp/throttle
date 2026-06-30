import XCTest
@testable import Throttle

/// Locks the "2h 14m" reset-countdown format now shown in the menu-bar dropdown
/// (alongside the wall-clock "resets 9pm") as well as the cockpit binding.
@MainActor
final class CockpitCountdownTests: XCTestCase {
    func test_countdown_formats() {
        XCTAssertEqual(MultiCockpitModel.countdown(0), "now")
        XCTAssertEqual(MultiCockpitModel.countdown(-5), "now")
        XCTAssertEqual(MultiCockpitModel.countdown(59), "0m")
        XCTAssertEqual(MultiCockpitModel.countdown(60), "1m")
        XCTAssertEqual(MultiCockpitModel.countdown(3600), "1h 0m")
        XCTAssertEqual(MultiCockpitModel.countdown(3700), "1h 1m")
        XCTAssertEqual(MultiCockpitModel.countdown(8160), "2h 16m")
    }
}
