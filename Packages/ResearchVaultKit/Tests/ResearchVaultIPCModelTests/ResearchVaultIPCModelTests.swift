import Foundation
import ResearchVaultIPCModel
import Testing

/// The format, refusal and boundary tests moved with the contract to
/// `Packages/ThrottleVaultContract`. This target only depends on the product
/// module and proves that the historical import still reaches every type.
@Suite("Research Vault IPC model re-export")
struct ResearchVaultIPCModelTests {
    @Test("the historical product import resolves the canonical contract")
    func historicalImportResolvesContractTypes() throws {
        let request = try ResearchVaultSearchRequest(query: "evidence", projectKeys: ["throttle"]).validated()
        #expect(request.contractVersion == ResearchVaultIPCContract.currentVersion)

        let receipt = try ResearchReceipt.seal(
            sessionID: "re-export",
            agentID: "test-agent",
            projectKey: "throttle",
            question: "Does the product import still reach the receipt format?",
            findings: [],
            sources: [],
            sensitivity: .internal,
            createdAt: Date(timeIntervalSince1970: 1_787_832_000)
        )
        let batch = try ResearchVaultReceiptImportRequest(receipts: [receipt]).validated()
        #expect(batch.receipts.map(\.receiptID) == [receipt.receiptID])
        #expect(try ResearchVaultContextBundle(
            query: "evidence", projectKeys: ["throttle"], maximumSensitivity: .internal, items: [], truncated: false
        ).encodedForIPC().count <= ResearchVaultIPCContract.maximumResponseBytes)
        #expect(ResearchVaultServiceContract.serviceSigningIdentifier == "com.lorislab.throttle.research-vault-agent")
    }
}
