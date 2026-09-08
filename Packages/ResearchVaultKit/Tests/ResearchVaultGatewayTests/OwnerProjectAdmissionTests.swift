import Foundation
import ResearchVaultGateway
import ResearchVaultIPCModel
import ResearchVaultModel
import ResearchVaultSQLCipher
import ResearchVaultStore
import Testing

@Suite("Explicit owner project admission")
struct OwnerProjectAdmissionTests {
    @Test("receipt metadata cannot admit a project and query clients cannot grant one")
    func metadataCannotGrant() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try fixture.open()
        let owner = try await ResearchVaultGateway.owner(store: store, baseline: fixture.ownerGrant)
        let reader = ResearchVaultGateway(store: store, authorization: fixture.readerGrant)
        await #expect(throws: ResearchVaultProjectAdmissionError.ownerRequired) {
            try await reader.admitProjects(.init(projectKeys: ["new-project"]))
        }
        await #expect(throws: ReceiptStoreError.authorizationDenied) {
            try await owner.importReceiptsForReview([fixture.receipt(project: "new-project")])
        }
        #expect(try await store.verifyIntegrity().receiptCount == 0)
    }

    @Test("admission survives service restart, preserves quarantine and does not widen third-party queries")
    func persistentOwnerGrant() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try fixture.open()
        let owner = try await ResearchVaultGateway.owner(store: store, baseline: fixture.ownerGrant)
        let receipt = try fixture.receipt(project: "new-project")
        _ = try await owner.admitProjects(.init(projectKeys: [receipt.projectKey]))
        _ = try await owner.importReceiptsForReview([receipt])
        #expect(try await owner.context(query: "admission sentinel").items.isEmpty)
        _ = try await owner.review(.init(action: .approve, receiptIDs: [receipt.receiptID]))
        #expect(try await owner.context(query: "admission sentinel").items.count == 1)
        await store.close()

        let reopened = try fixture.open()
        let restored = try await ResearchVaultGateway.owner(store: reopened, baseline: fixture.ownerGrant)
        let reader = ResearchVaultGateway(store: reopened, authorization: fixture.readerGrant)
        #expect(try await restored.context(query: "admission sentinel").items.count == 1)
        #expect(try await reader.context(query: "admission sentinel").items.isEmpty)
        #expect(
            try await reader.context(query: "admission sentinel", projectKeys: [receipt.projectKey])
                .projectKeys.isEmpty)
        #expect(try await reopened.verifyIntegrity().schemaVersion == SQLCipherReceiptStore.currentSchemaVersion)
    }

    @Test("concurrent admissions retain both grants")
    func concurrentAdmissions() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try fixture.open()
        let owner = try await ResearchVaultGateway.owner(store: store, baseline: fixture.ownerGrant)
        async let first = owner.admitProjects(.init(projectKeys: ["first-project"]))
        async let second = owner.admitProjects(.init(projectKeys: ["second-project"]))
        _ = try await (first, second)
        let response = try await owner.importReceiptsForReview([
            fixture.receipt(project: "first-project"), fixture.receipt(project: "second-project")
        ])
        #expect(response.insertedReceipts == 2)
        #expect(try await owner.quarantine().items.count == 2)
    }

    @Test("invalid or duplicate project grants are rejected")
    func malformedAdmission() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try fixture.open()
        let owner = try await ResearchVaultGateway.owner(store: store, baseline: fixture.ownerGrant)
        for keys in [[], ["*"], ["../outside"], ["UPPER"], ["same", "same"]] {
            await #expect(throws: ResearchVaultProjectAdmissionError.invalidProjects) {
                try await owner.admitProjects(.init(projectKeys: keys))
            }
        }
    }

    @Test("long owner-admitted project keys are searchable without widening query-only grants")
    func longProjectKeyScopedSearch() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try fixture.open()
        let owner = try await ResearchVaultGateway.owner(store: store, baseline: fixture.ownerGrant)
        let reader = ResearchVaultGateway(store: store, authorization: fixture.readerGrant)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for length in [64, 65, 128] {
            let key = String(repeating: "a", count: length)
            let admission = try decoder.decode(
                ResearchVaultProjectAdmissionRequest.self,
                from: encoder.encode(ResearchVaultProjectAdmissionRequest(projectKeys: [key]))
            ).validated()
            _ = try await owner.admitProjects(admission)
            let receipt = try fixture.receipt(project: key)
            _ = try await owner.importReceiptsForReview([receipt])
            _ = try await owner.review(.init(action: .approve, receiptIDs: [receipt.receiptID]))
            let request = try decoder.decode(
                ResearchVaultSearchRequest.self,
                from: encoder.encode(ResearchVaultSearchRequest(query: "admission sentinel", projectKeys: [key]))
            ).validated()
            let result = try await owner.context(query: request.query, projectKeys: request.projectKeys)
            #expect(result.items.count == 1)
            #expect(result.items.first?.citation.receiptProvenance?.receiptID == receipt.receiptID)
            #expect(result.projectKeys == [key])
            #expect(try await reader.context(query: request.query, projectKeys: request.projectKeys).items.isEmpty)
        }
        let tooLong = String(repeating: "a", count: 129)
        await #expect(throws: ResearchVaultProjectAdmissionError.invalidProjects) {
            try await owner.admitProjects(.init(projectKeys: [tooLong]))
        }
        #expect(try await owner.context(query: "admission sentinel", projectKeys: [tooLong]).projectKeys.isEmpty)
    }
}

private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-admission-" + UUID().uuidString)
    let key = Data(repeating: 0x73, count: 32)
    let ownerGrant = VaultAuthorization(projectKeys: ["throttle", "cheatcode"], maximumSensitivity: .restricted)
    let readerGrant = VaultAuthorization(projectKeys: ["throttle", "cheatcode"], maximumSensitivity: .internal)

    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

    func open() throws -> SQLCipherReceiptStore {
        try SQLCipherReceiptStore(databaseURL: root.appendingPathComponent("vault.ccsql"), key: key)
    }

    func receipt(project: String) throws -> ResearchReceipt {
        try ResearchReceipt.seal(
            receiptID: UUID().uuidString.lowercased(), sessionID: "admission-test", agentID: "test",
            projectKey: project, question: "admission sentinel",
            findings: [.init(claim: "admission sentinel " + project, status: .supported, evidenceIDs: ["source"])],
            sources: [.init(id: "source", kind: .file, locator: "fixture.md", observedAt: Date(),
                            sha256: String(repeating: "a", count: 64))],
            sensitivity: .internal, createdAt: Date()
        )
    }
}
