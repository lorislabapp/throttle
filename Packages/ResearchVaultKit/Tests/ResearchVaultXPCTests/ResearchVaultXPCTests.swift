import Foundation
import ResearchVaultIPCModel
import ResearchVaultModel
import ResearchVaultServiceRuntime
import ResearchVaultXPC
import ResearchVaultXPCClient
import Testing

@Suite("Research Vault XPC trust policy")
struct ResearchVaultXPCTests {
    @Test("async service lifetime suspends until structured cancellation")
    func serviceLifetimeIsCancellable() async {
        let lifetime = Task {
            await ResearchVaultServiceLifetime.waitUntilCancelled()
        }

        let firstCompletion = await withTaskGroup(of: String.self) { group in
            group.addTask {
                await lifetime.value
                return "lifetime"
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(100))
                return "timeout"
            }
            let first = await group.next()!
            lifetime.cancel()
            group.cancelAll()
            return first
        }

        #expect(firstCompletion == "timeout")
        await lifetime.value
    }

    @Test("CheatCode client contract is canonical and query-only")
    func cheatCodeClientContractIsQueryOnly() async throws {
        #expect(
            ResearchVaultServiceContract.cheatCodeQueryServiceName
                == ResearchVaultServiceRuntime.cheatCodeQueryServiceName
        )
        #expect(
            ResearchVaultServiceContract.serviceSigningIdentifier
                == ResearchVaultServiceRuntime.signingIdentifier
        )
        #expect(
            ResearchVaultServiceContract.teamIdentifier
                == ResearchVaultServiceRuntime.teamIdentifier
        )

        let client = try ResearchVaultServiceContract.makeCheatCodeClient()
        let receipt = try ResearchReceipt.seal(
            receiptID: "8f6ff598-fc26-4ad8-a3d7-fc16bcd7e1a0",
            sessionID: "query-only-client-test",
            agentID: "test-agent",
            projectKey: "cheatcode",
            question: "Can a query-only client import?",
            findings: [],
            sources: [],
            sensitivity: .internal,
            createdAt: Date(timeIntervalSince1970: 1_787_832_000)
        )
        await #expect(throws: ResearchVaultClientError.invalidConfiguration) {
            _ = try await client.importReceipts([receipt])
        }
    }

    @Test("Apple distribution requirement compiles")
    func requirementCompiles() throws {
        let identity = try ResearchVaultCodeIdentity(
            signingIdentifier: "com.kevinnadjarian.cheatcode",
            teamIdentifier: "TDV6D5L785"
        )
        try ResearchVaultCodeRequirement.validate(identity.distributionRequirement)
        #expect(identity.distributionRequirement.contains("anchor apple generic"))
        #expect(identity.distributionRequirement.contains("com.kevinnadjarian.cheatcode"))
        #expect(identity.distributionRequirement.contains("TDV6D5L785"))
        #expect(identity.distributionRequirement.contains("1.2.840.113635.100.6.1.12"))
        #expect(
            identity.distributionRequirement.range(of: "subject.OU")!.lowerBound
                < identity.distributionRequirement.range(of: "100.6.1.12")!.lowerBound
        )
    }

    @Test("identity inputs cannot inject requirement syntax")
    func rejectsRequirementInjection() {
        #expect(throws: ResearchVaultXPCConfigurationError.invalidSigningIdentifier) {
            try ResearchVaultCodeIdentity(
                signingIdentifier: "com.example.good\" or true",
                teamIdentifier: "TDV6D5L785"
            )
        }
        #expect(throws: ResearchVaultXPCConfigurationError.invalidTeamIdentifier) {
            try ResearchVaultCodeIdentity(
                signingIdentifier: "com.example.good",
                teamIdentifier: "TEAM\" OR TRUE"
            )
        }
    }

    @Test("endpoint grant is immutable and non-empty")
    func endpointPolicy() throws {
        let identity = try ResearchVaultCodeIdentity(
            signingIdentifier: "com.kevinnadjarian.cheatcode",
            teamIdentifier: "TDV6D5L785"
        )
        let authorization = VaultAuthorization(
            projectKeys: ["cheatcode"],
            maximumSensitivity: .internal
        )
        let policy = try ResearchVaultQueryEndpointPolicy(
            machServiceName: "com.lorislab.throttle.research-vault.query.cheatcode",
            authorizedClient: identity,
            authorization: authorization
        )
        #expect(policy.authorization == authorization)
        #expect(policy.authorizedClient == identity)
    }

    @Test("owner endpoint is a distinct immutable role")
    func ownerEndpointPolicy() throws {
        let identity = try ResearchVaultCodeIdentity(
            signingIdentifier: "com.lorislab.throttle",
            teamIdentifier: "TDV6D5L785"
        )
        let authorization = VaultAuthorization(
            projectKeys: ["cheatcode", "throttle"],
            maximumSensitivity: .restricted
        )
        let policy = try ResearchVaultOwnerEndpointPolicy(
            machServiceName: "com.lorislab.throttle.research-vault.owner.throttle",
            authorizedClient: identity,
            authorization: authorization
        )
        #expect(policy.authorization == authorization)
        #expect(policy.authorizedClient == identity)
    }

    @Test("owner request accepts only bounded sealed receipts")
    func ownerRequestValidation() throws {
        let receipt = try ResearchReceipt.seal(
            sessionID: "session-1",
            agentID: "agent-1",
            projectKey: "throttle",
            question: "What changed?",
            findings: [],
            sources: [],
            sensitivity: .internal
        )
        let request = try ResearchVaultReceiptImportRequest(receipts: [receipt]).validated()
        #expect(request.receipts == [receipt])
        #expect(throws: ResearchVaultIPCValidationError.invalidReceiptBatch) {
            try ResearchVaultReceiptImportRequest(receipts: []).validated()
        }
        #expect(throws: ResearchVaultIPCValidationError.invalidReceiptBatch) {
            try ResearchVaultReceiptImportRequest(
                receipts: Array(
                    repeating: receipt,
                    count: ResearchVaultIPCContract.maximumReceiptsPerRequest + 1
                )
            ).validated()
        }
    }

    @Test("owner service dispatches a validated content-only request")
    func ownerServiceDispatch() async throws {
        let receipt = try Self.receipt(id: "dispatch")
        let service = ResearchVaultOwnerService { receipts in
            #expect(receipts == [receipt])
            return ResearchVaultReceiptImportResponse(
                insertedReceipts: 1,
                alreadyPresentReceipts: 0
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let request = try encoder.encode(ResearchVaultReceiptImportRequest(receipts: [receipt]))
        let responseData: Data = await withCheckedContinuation { continuation in
            service.importReceipts(request) { continuation.resume(returning: $0) }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let response = try decoder.decode(ResearchVaultReceiptImportResponse.self, from: responseData)
        #expect(response.insertedReceipts == 1)
        #expect(response.contractVersion == ResearchVaultIPCContract.currentVersion)
    }

    @Test("owner service rejects malformed bytes before invoking importer")
    func ownerServiceRejectsMalformedBytes() async throws {
        let counter = InvocationCounter()
        let service = ResearchVaultOwnerService { _ in
            await counter.increment()
            return ResearchVaultReceiptImportResponse(
                insertedReceipts: 0,
                alreadyPresentReceipts: 0
            )
        }
        let responseData: Data = await withCheckedContinuation { continuation in
            service.importReceipts(Data("not-json".utf8)) {
                continuation.resume(returning: $0)
            }
        }
        let payload = try JSONDecoder().decode(ResearchVaultIPCErrorPayload.self, from: responseData)
        #expect(payload.code == .invalidRequest)
        #expect(await counter.value == 0)
    }

    private static func receipt(id: String) throws -> ResearchReceipt {
        let sourceID = "source-" + id
        return try ResearchReceipt.seal(
            receiptID: "10000000-0000-4000-8000-000000000001",
            sessionID: "session-" + id,
            agentID: "xpc-test",
            projectKey: "throttle",
            question: "Can the owner dispatch safely?",
            findings: [
                ResearchFinding(claim: "validated dispatch", status: .supported, evidenceIDs: [sourceID]),
            ],
            sources: [
                ResearchSource(
                    id: sourceID,
                    kind: .file,
                    locator: "evidence/dispatch.md",
                    observedAt: Date(timeIntervalSince1970: 1_787_832_000),
                    sha256: String(repeating: "e", count: 64)
                ),
            ],
            sensitivity: .internal,
            createdAt: Date(timeIntervalSince1970: 1_787_832_000)
        )
    }
}

private actor InvocationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
