@testable import ThrottleShared
import XCTest

final class GoliathControlPlaneTests: XCTestCase {
    private let trace = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    private let artifact = "7c5c2827757fcd67c6a9f59865b30a18863516de4af70fba0fa6c9e16a565bc7"

    private func receipt() -> GoliathControlPlane.Receipt {
        let hash = GoliathControlPlane.Receipt.eventHash(
            actionId: "018f4b88-4bc4-7c2a-8e9a-b88b152f43bd", traceparent: trace, sequence: 7,
            component: "supergateway", decision: "allowed", inputBytes: 512, outputBytes: 64,
            estimatedTokensBefore: 100, estimatedTokensAfter: 16, artifactSha256: artifact)
        XCTAssertEqual(hash, "2c78bb55af2891120148497e881543d66f889eeb8f21f3e0c320ea87b473d32f")
        return .init(
            actionId: "018f4b88-4bc4-7c2a-8e9a-b88b152f43bd", traceparent: trace, sequence: 7,
            component: "supergateway", decision: "allowed", inputBytes: 512, outputBytes: 64,
            estimatedTokensBefore: 100, estimatedTokensAfter: 16,
            artifactSha256: artifact, eventSha256: hash)
    }

    func testReceiptRoundTripAndIdempotentAccounting() throws {
        let encoded = try JSONEncoder().encode(receipt())
        let decoded = try JSONDecoder().decode(GoliathControlPlane.Receipt.self, from: encoded)
        var ledger = GoliathControlPlane.AccountingLedger()
        XCTAssertTrue(try ledger.consume(decoded))
        XCTAssertFalse(try ledger.consume(decoded))
        XCTAssertEqual(ledger.snapshot.acceptedEvents, 1)
        XCTAssertEqual(ledger.snapshot.estimatedTokensSaved, 84)
    }

    func testTamperedReceiptFailsClosed() throws {
        let valid = receipt()
        let tampered = GoliathControlPlane.Receipt(
            actionId: valid.actionId, traceparent: valid.traceparent, sequence: valid.sequence,
            component: valid.component, decision: valid.decision,
            inputBytes: valid.inputBytes, outputBytes: valid.outputBytes + 1,
            estimatedTokensBefore: valid.estimatedTokensBefore,
            estimatedTokensAfter: valid.estimatedTokensAfter,
            artifactSha256: valid.artifactSha256, eventSha256: valid.eventSha256)
        XCTAssertThrowsError(try tampered.validate()) {
            XCTAssertEqual($0 as? GoliathControlPlane.ContractError, .hashMismatch)
        }
    }

    func testDurableAccountingSurvivesRestartAndRemainsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("cfo.json")
        let first = try GoliathControlPlane.DurableAccountingStore(fileURL: journal).consume(receipt())
        let restarted = try GoliathControlPlane.DurableAccountingStore(fileURL: journal).consume(receipt())
        XCTAssertTrue(first.inserted)
        XCTAssertFalse(restarted.inserted)
        XCTAssertEqual(restarted.snapshot.acceptedEvents, 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: journal.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
}
