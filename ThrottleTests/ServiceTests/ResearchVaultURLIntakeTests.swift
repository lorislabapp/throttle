import Foundation
import ResearchVaultModel
@testable import Throttle
import XCTest

final class ResearchVaultURLIntakeTests: XCTestCase {
    func testRejectsNonHTTPS() {
        XCTAssertThrowsError(try ResearchVaultURLIntake.receipt(
            url: URL(string: "http://example.com")!,
            mimeType: "text/html",
            bytes: Data("x".utf8),
            projectKey: "url-intake",
            sensitivity: .internal
        )) {
            XCTAssertEqual($0 as? ResearchVaultURLIntakeError, .invalidScheme)
        }
    }

    func testRejectsOversizedBody() {
        let bytes = Data(repeating: 0x61, count: ResearchVaultURLIntake.maximumBytes + 1)
        XCTAssertThrowsError(try ResearchVaultURLIntake.receipt(
            url: URL(string: "https://example.com/doc")!,
            mimeType: "text/plain",
            bytes: bytes,
            projectKey: "url-intake",
            sensitivity: .internal
        )) {
            XCTAssertEqual($0 as? ResearchVaultURLIntakeError, .responseTooLarge)
        }
    }

    func testHTMLBecomesOpenReceiptWithURLSource() throws {
        let html = Data("<html><body><p>Grounded fact.</p></body></html>".utf8)
        let receipt = try ResearchVaultURLIntake.receipt(
            url: URL(string: "https://example.com/article")!,
            mimeType: "text/html",
            bytes: html,
            projectKey: "url-intake",
            sensitivity: .internal
        )
        XCTAssertEqual(receipt.sources.first?.kind, .url)
        XCTAssertEqual(receipt.sources.first?.locator, "https://example.com/article")
        XCTAssertTrue(receipt.findings.allSatisfy { $0.status == .open })
        XCTAssertTrue(receipt.findings.contains { $0.claim.contains("Grounded fact") })
    }

    func testRejectsUnsupportedAndEmptyContent() {
        XCTAssertThrowsError(try ResearchVaultURLIntake.receipt(
            url: URL(string: "https://example.com/image")!,
            mimeType: "image/png",
            bytes: Data([0x89, 0x50]),
            projectKey: "url-intake",
            sensitivity: .internal
        )) {
            XCTAssertEqual($0 as? ResearchVaultURLIntakeError, .unsupportedContent)
        }
        XCTAssertThrowsError(try ResearchVaultURLIntake.receipt(
            url: URL(string: "https://example.com/empty")!,
            mimeType: "text/plain",
            bytes: Data("   \n".utf8),
            projectKey: "url-intake",
            sensitivity: .internal
        )) {
            XCTAssertEqual($0 as? ResearchVaultURLIntakeError, .emptyExtraction)
        }
    }
}
