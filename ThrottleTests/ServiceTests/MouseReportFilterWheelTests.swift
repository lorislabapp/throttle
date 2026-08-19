import XCTest
@testable import ThrottleShared

/// The filter must keep dropping the garbage that motivated it (motion reports)
/// while letting wheel reports through — otherwise a full-screen TUI can never
/// be scrolled, which is exactly the bug this pairs with.
final class MouseReportFilterWheelTests: XCTestCase {
    private func run(_ s: String) -> String {
        var f = MouseReportFilter()
        return String(decoding: f.filter(Array(s.utf8)), as: UTF8.self)
    }

    func testWheelReportsPass() {
        XCTAssertEqual(run("\u{1B}[<64;10;5M"), "\u{1B}[<64;10;5M")
        XCTAssertEqual(run("\u{1B}[<65;10;5M"), "\u{1B}[<65;10;5M")
    }

    func testWheelWithModifiersPasses() {
        XCTAssertEqual(run("\u{1B}[<68;3;3M"), "\u{1B}[<68;3;3M")   // 64 + shift(4)
        XCTAssertEqual(run("\u{1B}[<80;3;3M"), "\u{1B}[<80;3;3M")   // 64 + control(16)
    }

    func testMotionAndClicksStillDropped() {
        XCTAssertEqual(run("\u{1B}[<35;97;40M"), "")   // the original garbage
        XCTAssertEqual(run("\u{1B}[<0;5;5M"), "")      // left press
        XCTAssertEqual(run("\u{1B}[<0;5;5m"), "")      // left release
        XCTAssertEqual(run("\u{1B}[M abc"), "c")       // X10: drops the 3 payload bytes (" ab")
    }

    func testKeyboardInputUntouched() {
        XCTAssertEqual(run("\u{1B}[A"), "\u{1B}[A")
        XCTAssertEqual(run("\u{1B}[200~hi\u{1B}[201~"), "\u{1B}[200~hi\u{1B}[201~")
        XCTAssertEqual(run("hello"), "hello")
    }
}
