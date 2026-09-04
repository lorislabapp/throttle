import CryptoKit
import Foundation
import ResearchVaultModel
import ResearchVaultReasoning
@_spi(ReasoningPersistence) import ResearchVaultSQLCipher
import XCTest

final class SQLCipherReasoningStoreTests: XCTestCase {
    func testApprovedEvidencePersistsSnapshotAndMismatchPurgesCache() async throws {
        let fixture = try makeFixture("roundtrip")
        let store = try SQLCipherReceiptStore(databaseURL: fixture.database, key: fixture.key)
        let authorization = VaultAuthorization(
            projectKeys: ["throttle"],
            maximumSensitivity: .restricted
        )
        _ = try await store.importReceipt(
            fixture.receipt,
            authorization: authorization,
            reviewState: .approved
        )
        let base = fact(evidence: fixture.evidence)
        let generation = try await store.replaceReasoningBaseFacts(
            [base],
            forProject: "throttle",
            authorization: authorization
        )
        XCTAssertEqual(generation, 1)

        let rule = ResearchRule(
            id: "approved-to-trusted",
            head: ResearchAtom(predicate: "trusted", terms: [.variable("x")]),
            body: [ResearchAtom(predicate: "approved", terms: [.variable("x")])]
        )
        let snapshot = try ResearchReasoningEngine().evaluate(baseFacts: [base], rules: [rule])
        let hash = rulePackHash([rule])
        try await store.persistReasoningCache(
            snapshot,
            baseGeneration: generation,
            rulePackHash: hash,
            engineVersion: "swift-positive-v1"
        )
        await store.close()
        let reopened = try SQLCipherReceiptStore(databaseURL: fixture.database, key: fixture.key)
        let loaded = try await reopened.loadReasoningCache(
            rulePackHash: hash,
            engineVersion: "swift-positive-v1"
        )
        XCTAssertEqual(loaded?.baseGeneration, generation)
        XCTAssertEqual(loaded?.baseFacts, [base])
        XCTAssertEqual(loaded?.derivedFacts, snapshot.facts(predicate: "trusted"))
        XCTAssertEqual(loaded?.derivations, snapshot.derivations)

        let mismatch = try await reopened.loadReasoningCache(
            rulePackHash: String(repeating: "f", count: 64),
            engineVersion: "swift-positive-v1"
        )
        XCTAssertNil(mismatch)
        let cacheCount = try await reopened.reasoningCacheFactCount()
        XCTAssertEqual(cacheCount, 0)
    }

    func testQuarantinedReceiptCannotCreateActiveBaseFact() async throws {
        let fixture = try makeFixture("quarantine")
        let store = try SQLCipherReceiptStore(databaseURL: fixture.database, key: fixture.key)
        let authorization = VaultAuthorization(
            projectKeys: ["throttle"],
            maximumSensitivity: .restricted
        )
        _ = try await store.importReceipt(
            fixture.receipt,
            authorization: authorization,
            reviewState: .quarantined
        )
        do {
            _ = try await store.replaceReasoningBaseFacts(
                [fact(evidence: fixture.evidence)],
                forProject: "throttle",
                authorization: authorization
            )
            XCTFail("Quarantined evidence must fail closed")
        } catch let error as SQLCipherReasoningError {
            XCTAssertEqual(error, .unapprovedEvidence(
                receiptID: fixture.evidence.receiptID,
                sourceID: fixture.evidence.sourceID
            ))
        }
        let generation = try await store.activeReasoningGeneration()
        XCTAssertEqual(generation, 0)
    }

    func testFailedReplacementPreservesPriorGenerationAndCache() async throws {
        let fixture = try makeFixture("rollback")
        let store = try SQLCipherReceiptStore(databaseURL: fixture.database, key: fixture.key)
        let authorization = VaultAuthorization(
            projectKeys: ["throttle"],
            maximumSensitivity: .restricted
        )
        _ = try await store.importReceipt(
            fixture.receipt,
            authorization: authorization,
            reviewState: .approved
        )
        let valid = fact(evidence: fixture.evidence)
        let generation = try await store.replaceReasoningBaseFacts(
            [valid], forProject: "throttle", authorization: authorization
        )
        let rule = ResearchRule(
            id: "derive", head: ResearchAtom(predicate: "derived", terms: [.variable("x")]),
            body: [ResearchAtom(predicate: "approved", terms: [.variable("x")])]
        )
        let snapshot = try ResearchReasoningEngine().evaluate(baseFacts: [valid], rules: [rule])
        let hash = rulePackHash([rule])
        try await store.persistReasoningCache(
            snapshot, baseGeneration: generation,
            rulePackHash: hash, engineVersion: "swift-positive-v1"
        )

        let invalid = ResearchFact(
            predicate: "approved", arguments: ["bad"], projectKey: "throttle",
            sensitivity: .internal, assertedAt: Date(timeIntervalSince1970: 1_800_000_001),
            evidence: [.init(receiptID: fixture.evidence.receiptID, sourceID: "missing")]
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await store.replaceReasoningBaseFacts(
                [valid, invalid], forProject: "throttle", authorization: authorization
            )
        }
        let retainedGeneration = try await store.activeReasoningGeneration()
        let retainedCache = try await store.loadReasoningCache(
            rulePackHash: hash, engineVersion: "swift-positive-v1"
        )
        XCTAssertEqual(retainedGeneration, generation)
        XCTAssertNotNil(retainedCache)
    }

    private func fact(evidence: ResearchFactEvidence) -> ResearchFact {
        ResearchFact(
            predicate: "approved", arguments: ["doc-a"], projectKey: "throttle",
            sensitivity: .internal, assertedAt: Date(timeIntervalSince1970: 1_800_000_000),
            evidence: [evidence]
        )
    }

    private func rulePackHash(_ rules: [ResearchRule]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try! encoder.encode(rules)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeFixture(_ name: String) throws -> (
        database: URL,
        key: Data,
        receipt: ResearchReceipt,
        evidence: ResearchFactEvidence
    ) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ResearchVaultReasoning-" + UUID().uuidString + "-" + name,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let receiptID = UUID().uuidString.lowercased()
        let sourceID = "source-" + receiptID
        let receipt = try ResearchReceipt.seal(
            receiptID: receiptID,
            sessionID: "reasoning-test",
            agentID: "reasoning-test",
            projectKey: "throttle",
            question: "Explicit approved relation",
            findings: [ResearchFinding(
                claim: "doc-a is approved",
                status: .supported,
                evidenceIDs: [sourceID]
            )],
            sources: [ResearchSource(
                id: sourceID,
                kind: .file,
                locator: "/tmp/reasoning-source.md",
                observedAt: Date(timeIntervalSince1970: 1_800_000_000),
                sha256: String(repeating: "a", count: 64)
            )],
            sensitivity: .internal,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        return (
            directory.appendingPathComponent("vault.ccsql"),
            Data(repeating: 0x72, count: 32),
            receipt,
            ResearchFactEvidence(receiptID: receiptID, sourceID: sourceID)
        )
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
