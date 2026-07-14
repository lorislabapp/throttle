import XCTest
@testable import ThrottleShared

final class MouseReportFilterTests: XCTestCase {

    private func run(_ chunks: [[UInt8]]) -> [UInt8] {
        var f = MouseReportFilter()
        return chunks.flatMap { f.filter($0) }
    }

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testPlainTextPassesThrough() {
        XCTAssertEqual(run([bytes("hello claude\n")]), bytes("hello claude\n"))
    }

    func testSGRMouseReportDropped() {
        // ESC [ < 35;150;30 M — the exact flood shape from the field screenshot.
        XCTAssertEqual(run([bytes("\u{1b}[<35;150;30M")]), [])
        XCTAssertEqual(run([bytes("a\u{1b}[<7;30;95Mb")]), bytes("ab"))
        // release variant ends in lowercase m
        XCTAssertEqual(run([bytes("\u{1b}[<0;10;10m")]), [])
    }

    func testSGRReportSplitAcrossChunks() {
        XCTAssertEqual(run([bytes("\u{1b}[<35;1"), bytes("50;30Mok")]), bytes("ok"))
    }

    func testX10MouseReportDropped() {
        // ESC [ M + 3 raw bytes
        XCTAssertEqual(run([[0x1B] + bytes("[M") + [0x20, 0x21, 0x22] + bytes("x")]), bytes("x"))
    }

    func testKeyboardCSISequencesSurvive() {
        XCTAssertEqual(run([bytes("\u{1b}[A")]), bytes("\u{1b}[A"))          // arrow up
        XCTAssertEqual(run([bytes("\u{1b}[15~")]), bytes("\u{1b}[15~"))      // F5
        XCTAssertEqual(run([bytes("\u{1b}[1;5C")]), bytes("\u{1b}[1;5C"))    // ctrl-right
        XCTAssertEqual(run([bytes("\u{1b}[200~paste\u{1b}[201~")]),
                       bytes("\u{1b}[200~paste\u{1b}[201~"))                 // bracketed paste
    }

    func testLoneEscPassesImmediately() {
        // A bare Esc keypress must not be held hostage waiting for a next byte.
        var f = MouseReportFilter()
        XCTAssertEqual(f.filter([0x1B]) + f.filter(bytes("q")), [0x1B] + bytes("q"))
    }

    func testAltKeyPassesThrough() {
        XCTAssertEqual(run([[0x1B] + bytes("f")]), [0x1B] + bytes("f"))      // alt-f word jump
    }

    func testFloodOfMotionReportsFullyDropped() {
        let flood = Array(repeating: "\u{1b}[<35;48;54M", count: 200).joined()
        XCTAssertEqual(run([bytes(flood + "real")]), bytes("real"))
    }

    func testDeployStepsHeredocsAtColumnZero() {
        // Swift multiline-string indentation stripping must leave heredoc
        // terminators (B64/SUMS/UNIT) at column 0 or the remote bash never
        // finds them and the deploy hangs.
        let steps = EdgeAgentService.deploySteps(token: "tok", httpPort: 8787, agentSource: "x")
        let all = steps.map(\.script).joined(separator: "\n")
        for term in ["B64", "SUMS", "UNIT"] {
            XCTAssertTrue(all.contains("\n\(term)\n") || all.hasSuffix("\n\(term)"),
                          "heredoc terminator \(term) not at column 0")
        }
        XCTAssertFalse(all.contains(" B64"), "indented B64 terminator")
    }
}
