import Foundation
import ResearchVaultGateway
import ResearchVaultIPCModel
import ResearchVaultModel
import ResearchVaultSQLCipher
import ResearchVaultXPC
import Testing

/// Real service/decoder/gateway/SQLCipher in one process. This does not qualify
/// code-signing admission or communication with an installed XPC endpoint.
@Suite("Research Vault search wire envelope")
struct ResearchVaultQueryEnvelopeTests {
    @Test("64 long project keys and escaped Unicode fit while query UTF-8 remains bounded")
    func longScopeWithEscapedUnicode() async throws {
        let fixture = try QueryEnvelopeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let query = String(repeating: "é", count: 2_048)
        #expect(query.utf8.count == ResearchVaultIPCContract.maximumQueryBytes)
        let request = try ResearchVaultSearchRequest(query: query, projectKeys: fixture.keys).validated()
        let encoded = try JSONEncoder().encode(request)
        // Exercise the larger, equally valid ASCII JSON spelling of Unicode.
        let json = try #require(String(data: encoded, encoding: .utf8))
        let escaped = Data(json.replacingOccurrences(of: "é", with: "\\u00e9").utf8)
        #expect(escaped.count > ResearchVaultIPCContract.maximumQueryBytes + 512)
        #expect(escaped.count < ResearchVaultIPCContract.maximumSearchRequestBytes)
        let result = try await fixture.bundle(for: escaped)
        #expect(result.query == query)
        #expect(result.projectKeys == [fixture.keys[0]])
        #expect(result.items.isEmpty)
    }

    @Test("the service accepts exactly 64 KiB and rejects one more encoded byte")
    func exactWireBoundary() async throws {
        let fixture = try QueryEnvelopeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = try JSONEncoder().encode(ResearchVaultSearchRequest(query: "sentinel"))
        let limit = ResearchVaultIPCContract.maximumSearchRequestBytes
        #expect(limit == 65_536)
        // JSON whitespace belongs to the envelope, not the decoded query string.
        var exact = request + Data(repeating: 0x20, count: limit - request.count)
        #expect(exact.count == limit)
        #expect(try await fixture.bundle(for: exact).query == "sentinel")
        exact.append(0x20)
        #expect(try await fixture.error(for: exact) == .invalidRequest)
    }

    @Test("oversized data is rejected even when the gateway is unavailable")
    func oversizedMessageStopsBeforeGateway() async throws {
        let fixture = try QueryEnvelopeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.store.close()
        let request = try JSONEncoder().encode(ResearchVaultSearchRequest(query: "sentinel"))
        let over = request + Data(
            repeating: 0x20, count: ResearchVaultIPCContract.maximumSearchRequestBytes + 1 - request.count
        )
        #expect(try await fixture.error(for: over) == .invalidRequest)
    }

    @Test("malformed JSON is an invalid request and does not poison the next search")
    func malformedRequestsStayInvalid() async throws {
        let fixture = try QueryEnvelopeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for payload in [Data(), Data("{".utf8), Data("[]".utf8), Data("{}".utf8),
                        Data([0xFF, 0xFE]), Data(#"{"query":true}"#.utf8)] {
            #expect(try await fixture.error(for: payload) == .invalidRequest)
        }
        let valid = try JSONEncoder().encode(ResearchVaultSearchRequest(query: "sentinel"))
        #expect(try await fixture.bundle(for: valid).query == "sentinel")
    }

    @Test("a larger envelope never loosens decoded query, scope or result limits")
    func semanticLimitsRemainEnforced() async throws {
        let fixture = try QueryEnvelopeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let requests = [
            ResearchVaultSearchRequest(query: String(repeating: "a", count: 4_097)),
            ResearchVaultSearchRequest(query: String(repeating: "é", count: 2_049)),
            ResearchVaultSearchRequest(query: " \n\t"),
            ResearchVaultSearchRequest(query: "sentinel", projectKeys: fixture.keys + ["extra"]),
            ResearchVaultSearchRequest(query: "sentinel", projectKeys: [String(repeating: "a", count: 129)]),
            ResearchVaultSearchRequest(query: "sentinel", projectKeys: ["same", "same"]),
            ResearchVaultSearchRequest(query: "sentinel", projectKeys: ["../private"]),
            ResearchVaultSearchRequest(query: "sentinel", projectKeys: []),
            ResearchVaultSearchRequest(query: "sentinel", limit: 21),
            ResearchVaultSearchRequest(query: "sentinel", maximumCharacters: 50_001),
            ResearchVaultSearchRequest(contractVersion: 999, query: "sentinel")
        ]
        for request in requests {
            let data = try JSONEncoder().encode(request)
            #expect(data.count < ResearchVaultIPCContract.maximumSearchRequestBytes)
            #expect(try await fixture.error(for: data) == .invalidRequest)
        }
    }

    @Test("a wide wire scope cannot widen a third-party grant or expose another project's receipt")
    func thirdPartyGrantStaysFixed() async throws {
        let fixture = try QueryEnvelopeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let allowed = try await fixture.insert(project: fixture.keys[0])
        _ = try await fixture.insert(project: fixture.keys[1])
        let data = try JSONEncoder().encode(
            ResearchVaultSearchRequest(query: "sentinel", projectKeys: fixture.keys)
        )
        #expect(data.count > 4_608)
        let result = try await fixture.bundle(for: data)
        #expect(result.projectKeys == [fixture.keys[0]])
        #expect(result.items.count == 1)
        #expect(result.items.first?.citation.receiptProvenance?.receiptID == allowed)
        let denied = try JSONEncoder().encode(
            ResearchVaultSearchRequest(query: "sentinel", projectKeys: [fixture.keys[1]])
        )
        let empty = try await fixture.bundle(for: denied)
        #expect(empty.items.isEmpty)
        #expect(empty.projectKeys.isEmpty)
        await #expect(throws: ResearchVaultProjectAdmissionError.ownerRequired) {
            try await fixture.gateway.admitProjects(.init(projectKeys: [fixture.keys[1]]))
        }
    }
}

private struct QueryEnvelopeFixture {
    let root: URL
    let keys = (0..<64).map { String(repeating: "a", count: 126) + String(format: "%02d", $0) }
    let store: SQLCipherReceiptStore
    let gateway: ResearchVaultGateway
    let service: ResearchVaultQueryService

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-query-envelope-" + UUID().uuidString)
        store = try SQLCipherReceiptStore(
            databaseURL: root.appendingPathComponent("vault.ccsql"), key: Data(repeating: 0x32, count: 32)
        )
        gateway = ResearchVaultGateway(
            store: store, authorization: .init(projectKeys: [keys[0]], maximumSensitivity: .internal)
        )
        service = ResearchVaultQueryService(gateway: gateway)
    }

    func reply(for request: Data) async -> Data {
        await withCheckedContinuation { continuation in
            service.search(request) { continuation.resume(returning: $0) }
        }
    }

    func bundle(for request: Data) async throws -> ResearchVaultContextBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(ResearchVaultContextBundle.self, from: await reply(for: request))
    }

    func error(for request: Data) async throws -> ResearchVaultIPCErrorPayload.Code {
        try JSONDecoder().decode(ResearchVaultIPCErrorPayload.self, from: await reply(for: request)).code
    }

    func insert(project: String) async throws -> String {
        let receipt = try ResearchReceipt.seal(
            sessionID: "envelope-test", agentID: "fixture", projectKey: project,
            question: "sentinel", findings: [.init(claim: "sentinel", status: .open, evidenceIDs: [])],
            sources: [], sensitivity: .internal
        )
        _ = try await store.importReceipt(
            receipt, authorization: .init(projectKeys: Set(keys), maximumSensitivity: .internal),
            reviewState: .approved
        )
        return receipt.receiptID
    }
}
