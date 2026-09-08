import CryptoKit
import Foundation
import ResearchVaultGateway
import ResearchVaultIngestion
import ResearchVaultIPCModel
import ResearchVaultModel
import ResearchVaultSQLCipher
import Testing

@Suite("Receipt retrieval with sealed provenance")
struct ReceiptContextTests {
    @Test("same-text findings keep the selected ordinal and its own evidence")
    func exactFindingProvenance() async throws {
        let fixture = try ContextFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let receipt = try fixture.receipt()
        _ = try await fixture.store.importReceipt(receipt, authorization: fixture.grant, reviewState: .approved)
        let bundle = try await fixture.gateway.context(query: "retrieval sentinel")
        #expect(bundle.items.count == 1)
        let item = try #require(bundle.items.first)
        #expect(item.citation.receiptProvenance?.receiptID == receipt.receiptID)
        #expect(item.citation.receiptProvenance?.sealedContentHash == receipt.contentHash)
        #expect(item.citation.receiptProvenance?.findingIndex == 0)
        #expect(item.citation.receiptProvenance?.sources.map(\.id) == ["first"])
        #expect(item.citation.origins == ["first.md"])
        #expect(item.citation.evidenceStatus == .open)
        #expect(ResearchCitationVerifier.verify(bundle).valid)
    }

    @Test("mixed documents and receipts respect the shared size and result budgets")
    func mixedBudget() async throws {
        let fixture = try ContextFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.store.importReceipt(
            fixture.receipt(), authorization: fixture.grant, reviewState: .approved)
        let content = "retrieval sentinel " + String(repeating: "document text ", count: 30)
        let data = Data(content.utf8)
        _ = try await fixture.store.importDocument(.init(
            documentID: "fixture-document", title: "Document", projectKey: "throttle", category: "test",
            libraryPath: "document.md", origins: ["document.md"], content: content,
            plaintextSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: data.count, modifiedAt: fixture.date, sensitivity: .internal
        ), authorization: fixture.grant, reviewState: .approved)
        let both = try await fixture.gateway.context(query: "retrieval sentinel", limit: 2, maximumCharacters: 1000)
        #expect(both.items.count == 2)
        #expect(both.items.contains { $0.citation.receiptProvenance != nil })
        #expect(both.items.contains { $0.citation.documentID == "fixture-document" })
        let bounded = try await fixture.gateway.context(query: "retrieval sentinel", limit: 1, maximumCharacters: 256)
        #expect(bounded.items.count == 1)
        #expect(bounded.items.reduce(0) { $0 + $1.excerpt.count } <= 256)
        #expect(bounded.truncated)
        #expect(ResearchCitationVerifier.verify(bounded).valid)
    }

    @Test("quarantined and more sensitive receipt payloads stay outside retrieval")
    func visibilityFilters() async throws {
        let fixture = try ContextFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let restricted = try fixture.receipt(sensitivity: .restricted)
        _ = try await fixture.store.importReceipt(restricted, authorization: fixture.grant, reviewState: .approved)
        _ = try await fixture.store.importReceipt(
            fixture.receipt(), authorization: fixture.grant, reviewState: .quarantined)
        let reader = ResearchVaultGateway(store: fixture.store, authorization: .init(
            projectKeys: ["throttle"], maximumSensitivity: .internal
        ))
        #expect(try await reader.context(query: "retrieval sentinel").items.isEmpty)
        #expect(try await fixture.gateway.context(query: "no_matching_probe_phrase").items.isEmpty)
    }

    @Test("large source provenance is omitted as a whole before exceeding the IPC limit")
    func provenanceWireBudget() async throws {
        let fixture = try ContextFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sources: [ResearchSource] = (0..<40).map {
            .init(id: "source-\($0)", kind: .file,
                  locator: "source-\($0)/" + String(repeating: "x", count: 16_320),
                  observedAt: fixture.date, sha256: String(repeating: "c", count: 64))
        }
        for _ in 0..<2 {
            let receipt = try ResearchReceipt.seal(
                receiptID: UUID().uuidString.lowercased(), sessionID: "wire-budget", agentID: "test",
                projectKey: "throttle", question: "Provenance?",
                findings: [.init(claim: "retrieval sentinel", status: .supported, evidenceIDs: sources.map(\.id))],
                sources: sources, sensitivity: .internal, createdAt: fixture.date
            )
            #expect(try JSONEncoder().encode(receipt).count < ResearchVaultIPCContract.maximumOwnerRequestBytes)
            _ = try await fixture.store.importReceipt(receipt, authorization: fixture.grant, reviewState: .approved)
        }
        let bundle = try await fixture.gateway.context(query: "retrieval sentinel", limit: 2, maximumCharacters: 256)
        #expect(bundle.items.count == 1)
        #expect(bundle.truncated)
        #expect(bundle.items.first?.citation.receiptProvenance?.sources == sources)
        #expect(bundle.items.first?.citation.origins == sources.map(\.locator))
        #expect(try bundle.encodedForIPC().count <= ResearchVaultIPCContract.maximumResponseBytes)
        #expect(ResearchCitationVerifier.verify(bundle).valid)
    }
}

private struct ContextFixture {
    let root: URL
    let store: SQLCipherReceiptStore
    let gateway: ResearchVaultGateway
    let grant = VaultAuthorization(projectKeys: ["throttle"], maximumSensitivity: .restricted)
    let date = Date(timeIntervalSince1970: 1_787_832_000)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-context-" + UUID().uuidString)
        store = try SQLCipherReceiptStore(databaseURL: root.appendingPathComponent("vault.ccsql"),
                                         key: Data(repeating: 0x27, count: 32))
        gateway = ResearchVaultGateway(store: store, authorization: grant)
    }

    func receipt(sensitivity: ResearchSensitivity = .internal) throws -> ResearchReceipt {
        try ResearchReceipt.seal(
            receiptID: UUID().uuidString.lowercased(), sessionID: "context-test", agentID: "test",
            projectKey: "throttle", question: "Provenance?",
            findings: [
                .init(claim: "retrieval sentinel", status: .open, evidenceIDs: ["first"]),
                .init(claim: "retrieval sentinel", status: .supported, evidenceIDs: ["second"])
            ],
            sources: ["first", "second"].map {
                .init(
                    id: $0, kind: .file, locator: $0 + ".md", observedAt: date,
                    sha256: String(repeating: "c", count: 64))
            }, sensitivity: sensitivity, createdAt: date
        )
    }
}
