import CryptoKit
import Foundation
import ResearchVaultGateway
import ResearchVaultIngestion
import ResearchVaultModel
import ResearchVaultSQLCipher
import Testing

@Suite("Research Vault gateway")
struct ResearchVaultGatewayTests {
    @Test("returns bounded context with complete provenance")
    func contextBundle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-vault-gateway-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLCipherReceiptStore(
            databaseURL: root.appendingPathComponent("vault.ccsql"),
            key: Data(repeating: 0x61, count: 32)
        )
        let authorization = VaultAuthorization(
            projectKeys: ["throttle"], maximumSensitivity: .internal
        )
        let text = "# Evidence\n\nLocal synthesis requires provenance sentinel."
        let data = Data(text.utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let document = ResearchDocumentCandidate(
            documentID: "dr-gateway", title: "Gateway evidence", projectKey: "throttle",
            category: "test", libraryPath: "library/test/throttle/gateway.md",
            origins: ["/private/origin.md"], content: text, plaintextSHA256: hash,
            byteCount: data.count, modifiedAt: Date(timeIntervalSince1970: 1_787_832_000),
            sensitivity: .internal
        )
        _ = try await store.importDocument(document, authorization: authorization)
        let gateway = ResearchVaultGateway(store: store, authorization: authorization)
        let bundle = try await gateway.context(
            query: "provenance sentinel", maximumCharacters: 20
        )
        #expect(bundle.items.count == 1)
        #expect(bundle.items[0].citation.documentID == "dr-gateway")
        #expect(bundle.items[0].citation.plaintextSHA256 == hash)
        #expect(bundle.items[0].citation.origins == ["/private/origin.md"])
        #expect(bundle.items[0].citation.schemaVersion == 2)
        #expect(bundle.items[0].citation.locator == "library/test/throttle/gateway.md#chunk-0")
        #expect(bundle.items[0].citation.excerptSHA256.count == 64)
        #expect(bundle.items[0].citation.observedAt >= document.modifiedAt)
        #expect(bundle.items[0].citation.sourceModifiedAt == document.modifiedAt)
        #expect(bundle.items[0].citation.evidenceStatus == nil)
        #expect(bundle.items[0].citation.indexGeneration == "fts5-bm25-v1:1")
        #expect(bundle.items[0].excerpt.contains("provenance sentinel"))
        #expect(bundle.items[0].excerpt.count <= 256)
        #expect(bundle.projectKeys == ["throttle"])
    }

    @Test("publishes closed MCP-compatible schemas only")
    func toolSchemas() throws {
        #expect(ResearchVaultGateway.toolDefinitions.map(\.name) == [
            "research_vault_search", "research_vault_health",
        ])
        for tool in ResearchVaultGateway.toolDefinitions {
            let object = try JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8))
            #expect(object is [String: Any])
        }
    }
}
