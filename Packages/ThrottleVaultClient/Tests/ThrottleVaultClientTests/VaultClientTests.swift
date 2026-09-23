import Foundation
import ObjectiveC
import ThrottleVaultClient
import XCTest

final class VaultClientTests: XCTestCase {
    func testXPCInterfaceSelectorsMatchThePreExtractionCapture() throws {
        let fixture = try fixture()
        let current = XPCInterfaceCapture.capture()
        for key in ["queryProtocol", "ownerProtocol"] {
            XCTAssertEqual(
                XPCInterfaceCapture.selectors(current, key),
                XPCInterfaceCapture.selectors(fixture, key),
                key
            )
            XCTAssertFalse(XPCInterfaceCapture.selectors(current, key).isEmpty, key)
            let name = (current[key] as? [String: Any])?["runtimeName"] as? String ?? "?"
            print("\(key) runtime name after extraction: \(name)")
        }
        XCTAssertEqual(
            fixture["receiptFileSuffix"] as? String,
            ResearchVaultReceiptBatchReader.fileSuffix
        )
    }

    func testAppleDistributionRequirementCompiles() throws {
        let identity = try ResearchVaultCodeIdentity(
            signingIdentifier: "com.example.synthetic-client",
            teamIdentifier: "ABCDE12345"
        )
        try ResearchVaultCodeRequirement.validate(identity.distributionRequirement)
        XCTAssertThrowsError(try ResearchVaultCodeRequirement.validate("anchor apple generic and (")) { error in
            guard case .malformedCodeRequirement? = error as? ResearchVaultXPCConfigurationError else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testConnectionFactoryPinsTheInterfaceWithoutActivating() throws {
        let identity = try ResearchVaultCodeIdentity(
            signingIdentifier: ResearchVaultServiceContract.serviceSigningIdentifier,
            teamIdentifier: ResearchVaultServiceContract.teamIdentifier
        )
        let query = try ResearchVaultXPCConnectionFactory.queryConnection(
            machServiceName: ResearchVaultServiceContract.cheatCodeQueryServiceName,
            serviceIdentity: identity
        )
        defer { query.invalidate() }
        let owner = try ResearchVaultXPCConnectionFactory.ownerConnection(
            machServiceName: ResearchVaultServiceContract.throttleOwnerServiceName,
            serviceIdentity: identity
        )
        defer { owner.invalidate() }
        let queryProtocol = try XCTUnwrap(query.remoteObjectInterface?.protocol)
        let ownerProtocol = try XCTUnwrap(owner.remoteObjectInterface?.protocol)
        XCTAssertTrue(protocol_isEqual(queryProtocol, ResearchVaultQueryXPCProtocol.self))
        XCTAssertTrue(protocol_isEqual(ownerProtocol, ResearchVaultOwnerXPCProtocol.self))
        XCTAssertFalse(protocol_isEqual(queryProtocol, ownerProtocol))
        XCTAssertNil(query.exportedInterface)
        XCTAssertNil(owner.exportedInterface)
    }

    func testQueryOnlyClientRefusesOwnerOperationsBeforeConnecting() async throws {
        let client = try ResearchVaultServiceContract.makeCheatCodeClient()
        let receipt = try ResearchReceipt.seal(
            sessionID: "query-only",
            agentID: "test-agent",
            projectKey: "cheatcode",
            question: "Can a query-only client import?",
            findings: [],
            sources: [],
            sensitivity: .internal,
            createdAt: Date(timeIntervalSince1970: 1_787_832_000)
        )
        await expectClientError(.invalidConfiguration) { _ = try await client.importReceipts([receipt]) }
        await expectClientError(.invalidConfiguration) { _ = try await client.admitProjects(["cheatcode"]) }
        await expectClientError(.invalidConfiguration) { _ = try await client.quarantine() }
        await expectClientError(.invalidConfiguration) {
            _ = try await client.review(ids: [receipt.receiptID], action: .approve)
        }
        await expectClientError(.invalidConfiguration) { _ = try await client.exportReceipts() }
        await expectClientError(.invalidConfiguration) { _ = try await client.refreshReasoningRelations() }
        await expectClientError(.invalidConfiguration) {
            _ = try await client.reasoning(ResearchVaultReasoningQuery(kind: .contradictions))
        }
    }

    func testOutOfContractRequestsAreRefusedBeforeConnecting() async throws {
        let client = try ResearchVaultServiceContract.makeCheatCodeClient()
        do {
            let oversized = String(repeating: "q", count: ResearchVaultIPCContract.maximumQueryBytes + 1)
            _ = try await client.search(query: oversized)
            XCTFail("oversized query reached the transport")
        } catch let error as ResearchVaultIPCValidationError {
            XCTAssertEqual(error, .invalidQuery)
        }
        do {
            _ = try await client.search(query: "ok", limit: 0)
            XCTFail("invalid limit reached the transport")
        } catch let error as ResearchVaultIPCValidationError {
            XCTAssertEqual(error, .invalidLimit)
        }
    }

    func testMissingServiceFailsClosedAsUnavailable() async throws {
        let client = ResearchVaultClient(
            queryServiceName: "com.lorislab.throttle.research-vault.test.missing-\(UUID().uuidString.lowercased())",
            serviceIdentity: try ResearchVaultCodeIdentity(
                signingIdentifier: ResearchVaultServiceContract.serviceSigningIdentifier,
                teamIdentifier: ResearchVaultServiceContract.teamIdentifier
            )
        )
        await expectClientError(.serviceUnavailable) { _ = try await client.health() }
    }

    private func expectClientError(
        _ expected: ResearchVaultClientError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ResearchVaultClientError, expected, file: file, line: line)
        }
    }

    private func fixture() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "pre-extraction-xpc-interface", withExtension: "json", subdirectory: "Fixtures"
        ))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}
