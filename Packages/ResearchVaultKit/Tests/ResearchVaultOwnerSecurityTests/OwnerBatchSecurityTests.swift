import Foundation
import ResearchVaultModel
import ResearchVaultSQLCipher
import ResearchVaultStore
import Testing

@Suite("Owner receipt batch security")
struct OwnerBatchSecurityTests {
    @Test("unauthorized member leaves no partial import")
    func unauthorizedBatchIsAtomic() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try SQLCipherReceiptStore(databaseURL: fixture.database, key: fixture.key)
        let allowed = try receipt(id: "allowed", project: "throttle")
        let denied = try receipt(id: "denied", project: "outside-grant")
        let grant = VaultAuthorization(projectKeys: ["throttle"], maximumSensitivity: .internal)

        await #expect(throws: ReceiptStoreError.authorizationDenied) {
            try await store.importReceipts([allowed, denied], authorization: grant)
        }
        let evidence = try await store.verifyIntegrity()
        #expect(evidence.receiptCount == 0)
    }

    @Test("identical duplicate is idempotent within one transaction")
    func duplicateInBatchIsIdempotent() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try SQLCipherReceiptStore(databaseURL: fixture.database, key: fixture.key)
        let value = try receipt(id: "same", project: "throttle")
        let grant = VaultAuthorization(projectKeys: ["throttle"], maximumSensitivity: .internal)

        let result = try await store.importReceipts([value, value], authorization: grant)
        #expect(result.insertedReceipts == 1)
        #expect(result.alreadyPresentReceipts == 1)
        #expect(try await store.verifyIntegrity().receiptCount == 1)
    }

    private func receipt(id: String, project: String) throws -> ResearchReceipt {
        let sourceID = "source-" + id
        return try ResearchReceipt.seal(
            receiptID: "00000000-0000-4000-8000-" + String(id.hashValue.magnitude).suffix(12).leftPadded(to: 12),
            sessionID: "session-" + id,
            agentID: "security-test",
            projectKey: project,
            question: "Is the owner batch atomic?",
            findings: [
                ResearchFinding(claim: "atomic " + id, status: .supported, evidenceIDs: [sourceID]),
            ],
            sources: [
                ResearchSource(
                    id: sourceID,
                    kind: .file,
                    locator: "evidence/" + id + ".md",
                    observedAt: Date(timeIntervalSince1970: 1_787_832_000),
                    sha256: String(repeating: "d", count: 64)
                ),
            ],
            sensitivity: .internal,
            createdAt: Date(timeIntervalSince1970: 1_787_832_000)
        )
    }
}

private struct Fixture {
    let directory: URL
    let database: URL
    let key = Data(repeating: 0x42, count: 32)

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResearchVaultOwnerSecurity-" + UUID().uuidString)
        database = directory.appendingPathComponent("vault.ccsql")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

private extension Substring {
    func leftPadded(to count: Int) -> String {
        String(repeating: "0", count: Swift.max(0, count - self.count)) + self
    }
}
