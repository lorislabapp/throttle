import Foundation
import XCTest
import ResearchVaultModel
import ResearchVaultStore

final class ReceiptStoreTests: XCTestCase {
    func testImportIsIdempotent() async throws {
        let store = InMemoryReceiptStore()
        let receipt = try makeReceipt()
        let grant = VaultAuthorization(
            projectKeys: ["throttle"],
            maximumSensitivity: .internal
        )

        let first = try await store.importReceipt(receipt, authorization: grant)
        let second = try await store.importReceipt(receipt, authorization: grant)

        XCTAssertEqual(first, .inserted)
        XCTAssertEqual(second, .alreadyPresent)
        let stored = try await store.receipt(id: receipt.receiptID, authorization: grant)
        XCTAssertEqual(stored, receipt)
    }

    func testCrossProjectImportAndReadFailClosed() async throws {
        let store = InMemoryReceiptStore()
        let receipt = try makeReceipt()
        let throttleGrant = VaultAuthorization(
            projectKeys: ["throttle"],
            maximumSensitivity: .restricted
        )
        let cheatCodeGrant = VaultAuthorization(
            projectKeys: ["cheatcode"],
            maximumSensitivity: .restricted
        )

        _ = try await store.importReceipt(receipt, authorization: throttleGrant)

        do {
            _ = try await store.receipt(id: receipt.receiptID, authorization: cheatCodeGrant)
            XCTFail("Cross-project read must fail closed")
        } catch {
            XCTAssertEqual(error as? ReceiptStoreError, .authorizationDenied)
        }

        do {
            _ = try await store.importReceipt(receipt, authorization: cheatCodeGrant)
            XCTFail("Cross-project import must fail closed")
        } catch {
            XCTAssertEqual(error as? ReceiptStoreError, .authorizationDenied)
        }
    }

    func testListOnlyReturnsExplicitlyAuthorizedProjectsAndSensitivity() async throws {
        let store = InMemoryReceiptStore()
        let internalReceipt = try makeReceipt()
        let admin = VaultAuthorization(
            projectKeys: ["throttle"],
            maximumSensitivity: .restricted
        )
        _ = try await store.importReceipt(internalReceipt, authorization: admin)

        let publicOnly = VaultAuthorization(
            projectKeys: ["throttle"],
            maximumSensitivity: .public
        )
        let noProjects = VaultAuthorization(
            projectKeys: [],
            maximumSensitivity: .restricted
        )

        let publicResults = await store.receipts(authorization: publicOnly)
        let emptyResults = await store.receipts(authorization: noProjects)
        XCTAssertTrue(publicResults.isEmpty)
        XCTAssertTrue(emptyResults.isEmpty)
    }

    func testReceiptIDReuseWithDifferentValidContentIsConflict() async throws {
        let store = InMemoryReceiptStore()
        let first = try makeReceipt(question: "First question")
        let second = try makeReceipt(question: "Second question")
        let grant = VaultAuthorization(
            projectKeys: ["throttle"],
            maximumSensitivity: .restricted
        )
        _ = try await store.importReceipt(first, authorization: grant)

        do {
            _ = try await store.importReceipt(second, authorization: grant)
            XCTFail("Reusing a receipt ID with different content must fail")
        } catch {
            XCTAssertEqual(
                error as? ReceiptStoreError,
                .receiptIDConflict(first.receiptID)
            )
        }
    }

    private func makeReceipt(question: String = "How should research be stored?") throws -> ResearchReceipt {
        try ResearchReceipt.seal(
            receiptID: "b428edfd-cac5-42bd-b593-70aabdc72eef",
            sessionID: "session-1",
            agentID: "agent-1",
            projectKey: "throttle",
            question: question,
            findings: [
                ResearchFinding(
                    claim: "Receipts are stable.",
                    status: .supported,
                    evidenceIDs: ["source-1"]
                ),
            ],
            sources: [
                ResearchSource(
                    id: "source-1",
                    kind: .file,
                    locator: "docs/research/example.md",
                    observedAt: Date(timeIntervalSince1970: 1_787_832_000),
                    sha256: String(repeating: "b", count: 64)
                ),
            ],
            sensitivity: .internal,
            createdAt: Date(timeIntervalSince1970: 1_787_832_000)
        )
    }
}
