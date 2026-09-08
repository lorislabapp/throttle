import Foundation
@testable import Throttle
import XCTest

final class TaskIntegrationOutputTests: XCTestCase {
    func testVerboseCommandKeepsABoundedTailWhileDraining() {
        let collector = TaskIntegrationService.OutputCollector()
        let chunk = Data(repeating: 120, count: 1024 * 1024)
        for _ in 0..<64 {
            collector.append(chunk)
            XCTAssertLessThanOrEqual(collector.retainedByteCount, 64 * 1024)
        }
        collector.append(Data("\nFINAL: verification failed\n".utf8))
        XCTAssertTrue(collector.output.contains("FINAL: verification failed"))
        XCTAssertTrue(collector.output.contains("Earlier output omitted"))
        let displayed = TaskIntegrationService.boundedVerificationOutput(collector.output)
        XCTAssertLessThanOrEqual(displayed.count, 4000)
        XCTAssertTrue(displayed.contains("Earlier output omitted"))
        XCTAssertTrue(displayed.contains("FINAL: verification failed"))
        XCTAssertFalse(collector.timedOut)
        XCTAssertTrue(collector.consumeEOF())
        XCTAssertFalse(collector.consumeEOF())
    }

    func testSmallOutputIsUnchanged() {
        let collector = TaskIntegrationService.OutputCollector()
        collector.append(Data("Test réussi ✅\n".utf8))
        XCTAssertEqual(collector.output, "Test réussi ✅\n")
        XCTAssertEqual(TaskIntegrationService.boundedVerificationOutput(collector.output), collector.output)
    }

    func testDisplayLimitReportsTruncationBelowTheCollectorByteLimit() {
        let collector = TaskIntegrationService.OutputCollector()
        collector.append(Data((String(repeating: "x", count: 8000) + "\nFINAL ERROR").utf8))
        let output = TaskIntegrationService.boundedVerificationOutput(collector.output)
        XCTAssertLessThanOrEqual(output.count, 4000)
        XCTAssertTrue(output.contains("FINAL ERROR"))
        XCTAssertTrue(output.contains("Earlier output omitted"))
    }

    func testSplitUTF8AtTailBoundaryDoesNotEraseTheDiagnostic() {
        let collector = TaskIntegrationService.OutputCollector()
        collector.append(Data(repeating: 120, count: 64 * 1024 - 2))
        collector.append(Data("✅".utf8))
        collector.append(Data(repeating: 121, count: 64 * 1024 - 2))
        XCTAssertTrue(collector.output.contains("�"))
        collector.append(Data("END".utf8))
        XCTAssertEqual(collector.retainedByteCount, 64 * 1024)
        XCTAssertTrue(collector.output.contains("END"))
        XCTAssertTrue(collector.output.contains("Earlier output omitted"))
    }
}
