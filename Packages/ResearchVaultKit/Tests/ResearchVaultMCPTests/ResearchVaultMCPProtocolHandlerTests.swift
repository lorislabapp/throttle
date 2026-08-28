import CryptoKit
import Foundation
import ResearchVaultGateway
import ResearchVaultIngestion
import ResearchVaultMCP
import ResearchVaultModel
import ResearchVaultSQLCipher
import Testing

@Suite("Research Vault MCP protocol")
struct ResearchVaultMCPProtocolHandlerTests {
    @Test("lists closed tools and returns citation-first search content")
    func protocolRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-vault-mcp-test-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLCipherReceiptStore(
            databaseURL: root.appendingPathComponent("vault.ccsql"),
            key: Data(repeating: 0x71, count: 32)
        )
        let authorization = VaultAuthorization(
            projectKeys: ["throttle"], maximumSensitivity: .internal
        )
        let text = "# MCP\n\nCitation protocol sentinel."
        let bytes = Data(text.utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        _ = try await store.importDocument(
            ResearchDocumentCandidate(
                documentID: "dr-mcp", title: "MCP evidence", projectKey: "throttle",
                category: "test", libraryPath: "library/test/throttle/mcp.md",
                origins: ["/origin/mcp.md"], content: text, plaintextSHA256: hash,
                byteCount: bytes.count, modifiedAt: Date(timeIntervalSince1970: 1_787_832_000),
                sensitivity: .internal
            ),
            authorization: authorization
        )
        let handler = ResearchVaultMCPProtocolHandler(
            gateway: ResearchVaultGateway(store: store, authorization: authorization)
        )

        let list = try #require(await handler.handleLine(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8
        )))
        let listText = String(decoding: list, as: UTF8.self)
        #expect(listText.contains("research_vault_search"))
        #expect(listText.contains("additionalProperties\":false"))

        let search = try #require(await handler.handleLine(Data(
            #"{"jsonrpc":"2.0","id":"s","method":"tools/call","params":{"name":"research_vault_search","arguments":{"query":"protocol sentinel"}}}"#.utf8
        )))
        let searchText = String(decoding: search, as: UTF8.self)
        #expect(searchText.contains("dr-mcp"))
        #expect(searchText.contains(hash))
        #expect(searchText.contains("/origin/mcp.md"))
        #expect(!searchText.contains("isError\":true"))
    }

    @Test("rejects unknown tools without reflecting hostile input")
    func unknownTool() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-vault-mcp-error-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLCipherReceiptStore(
            databaseURL: root.appendingPathComponent("vault.ccsql"),
            key: Data(repeating: 0x72, count: 32)
        )
        let handler = ResearchVaultMCPProtocolHandler(gateway: ResearchVaultGateway(
            store: store,
            authorization: VaultAuthorization(projectKeys: ["throttle"], maximumSensitivity: .internal)
        ))
        let hostile = "steal-secret-" + UUID().uuidString
        let request = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"\(hostile)\",\"arguments\":{}}}"
        let response = try #require(await handler.handleLine(Data(request.utf8)))
        let text = String(decoding: response, as: UTF8.self)
        #expect(text.contains("Unknown tool"))
        #expect(!text.contains(hostile))
    }
}
