import CryptoKit
import Foundation
import ResearchVaultGateway
import ResearchVaultIngestion
import ResearchVaultIPCModel
import ResearchVaultModel
import ResearchVaultReasoning
@_spi(ReasoningPersistence) import ResearchVaultSQLCipher
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
        _ = try await store.importDocument(
            document,
            authorization: authorization,
            reviewState: .approved
        )
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

        let outsideGrant = try await gateway.context(
            query: "provenance sentinel",
            projectKeys: ["cheatcode"]
        )
        #expect(outsideGrant.items.isEmpty)
        #expect(outsideGrant.projectKeys.isEmpty)
    }

    @Test("owner intake remains invisible until an authorized review")
    func ownerIntakeQuarantineFlow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-vault-review-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLCipherReceiptStore(
            databaseURL: root.appendingPathComponent("vault.ccsql"),
            key: Data(repeating: 0x62, count: 32)
        )
        let authorization = VaultAuthorization(
            projectKeys: ["throttle"], maximumSensitivity: .internal
        )
        let sourceID = "source-review"
        let receipt = try ResearchReceipt.seal(
            receiptID: "20000000-0000-4000-8000-000000000001",
            sessionID: "review-flow",
            agentID: "gateway-test",
            projectKey: "throttle",
            question: "Should this evidence be approved?",
            findings: [
                ResearchFinding(
                    claim: "quarantine flow sentinel",
                    status: .open,
                    evidenceIDs: [sourceID]
                ),
            ],
            sources: [
                ResearchSource(
                    id: sourceID,
                    kind: .file,
                    locator: "evidence/review.md",
                    observedAt: Date(timeIntervalSince1970: 1_787_832_000),
                    sha256: String(repeating: "a", count: 64)
                ),
            ],
            sensitivity: .internal,
            createdAt: Date(timeIntervalSince1970: 1_787_832_000)
        )
        let gateway = ResearchVaultGateway(store: store, authorization: authorization)

        _ = try await gateway.importReceiptsForReview([receipt])
        #expect(try await store.searchClaims(
            query: "quarantine flow",
            limit: 10,
            authorization: authorization
        ).isEmpty)
        let pending = try await gateway.quarantine()
        #expect(pending.items.map(\.receiptID) == [receipt.receiptID])

        let result = try await gateway.review(
            ResearchVaultReviewRequest(
                action: .approve,
                receiptIDs: [receipt.receiptID]
            )
        )
        #expect(result.processed == 1)
        #expect(try await store.searchClaims(
            query: "quarantine flow",
            limit: 10,
            authorization: authorization
        ).count == 1)
        #expect(try await gateway.quarantine().items.isEmpty)
    }

    @Test("owner review cannot target a receipt outside its endpoint grant")
    func reviewScopeIsImmutable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-vault-review-scope-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLCipherReceiptStore(
            databaseURL: root.appendingPathComponent("vault.ccsql"),
            key: Data(repeating: 0x63, count: 32)
        )
        let fullAuthorization = VaultAuthorization(
            projectKeys: ["throttle", "private-project"], maximumSensitivity: .restricted
        )
        let restrictedGateway = ResearchVaultGateway(
            store: store,
            authorization: VaultAuthorization(
                projectKeys: ["throttle"], maximumSensitivity: .internal
            )
        )
        let receipt = try ResearchReceipt.seal(
            receiptID: "20000000-0000-4000-8000-000000000002",
            sessionID: "review-scope",
            agentID: "gateway-test",
            projectKey: "private-project",
            question: "Can another endpoint approve this?",
            findings: [],
            sources: [],
            sensitivity: .restricted,
            createdAt: Date(timeIntervalSince1970: 1_787_832_000)
        )
        _ = try await store.importReceipts(
            [receipt],
            authorization: fullAuthorization,
            reviewState: .quarantined
        )

        await #expect(throws: ResearchVaultGatewayError.reviewTargetUnavailable) {
            _ = try await restrictedGateway.review(
                ResearchVaultReviewRequest(action: .reject, receiptIDs: [receipt.receiptID])
            )
        }
        #expect(try await store.quarantinedReceipts(authorization: fullAuthorization).count == 1)
    }

    @Test("approved receipt export is scoped and cursor-paginated")
    func approvedReceiptExportIsPaginated() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-vault-export-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLCipherReceiptStore(
            databaseURL: root.appendingPathComponent("vault.ccsql"),
            key: Data(repeating: 0x64, count: 32)
        )
        let authorization = VaultAuthorization(
            projectKeys: ["throttle"], maximumSensitivity: .internal
        )
        let gateway = ResearchVaultGateway(store: store, authorization: authorization)
        let first = try Self.receipt(
            id: "40000000-0000-4000-8000-000000000001",
            createdAt: 1_787_832_001
        )
        let second = try Self.receipt(
            id: "40000000-0000-4000-8000-000000000002",
            createdAt: 1_787_832_002
        )
        let pending = try Self.receipt(
            id: "40000000-0000-4000-8000-000000000003",
            createdAt: 1_787_832_003
        )
        _ = try await gateway.importReceipts([first, second])
        _ = try await gateway.importReceiptsForReview([pending])

        let pageOne = try await gateway.exportApprovedReceipts(
            ResearchVaultReceiptExportRequest(limit: 1)
        )
        #expect(pageOne.receipts == [first])
        #expect(pageOne.nextReceiptID == first.receiptID)
        let pageTwo = try await gateway.exportApprovedReceipts(
            ResearchVaultReceiptExportRequest(
                afterReceiptID: pageOne.nextReceiptID,
                limit: 1
            )
        )
        #expect(pageTwo.receipts == [second])
        #expect(pageTwo.nextReceiptID == nil)
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

    @Test("owner promotion refreshes a separate bounded reasoning shadow")
    func reasoningShadow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-vault-reasoning-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLCipherReceiptStore(
            databaseURL: root.appendingPathComponent("vault.ccsql"),
            key: Data(repeating: 0x65, count: 32)
        )
        let authorization = VaultAuthorization(
            projectKeys: ["throttle"], maximumSensitivity: .internal
        )
        let gateway = ResearchVaultGateway(store: store, authorization: authorization)
        let first = try Self.reasoningReceipt(
            id: "50000000-0000-4000-8000-000000000001",
            sourceID: "source-a",
            claim: "Claim A"
        )
        let second = try Self.reasoningReceipt(
            id: "50000000-0000-4000-8000-000000000002",
            sourceID: "source-b",
            claim: "Claim B"
        )
        _ = try await gateway.importReceipts([first, second])
        let relation = ResearchVaultReasoningRelation(
            relation: .contradicts,
            subject: .init(receiptID: first.receiptID, findingIndex: 0),
            object: .init(receiptID: second.receiptID, findingIndex: 0)
        )

        let refresh = try await gateway.refreshReasoningShadow(
            ResearchVaultReasoningPromotionRequest(relations: [relation])
        )
        #expect(refresh.shadowMode)
        #expect(refresh.relationCount == 1)
        #expect(refresh.baseFactCount == 5)
        #expect(refresh.derivedFactCount == 0)

        let contradictions = try await gateway.reasoning(
            ResearchVaultReasoningQuery(kind: .contradictions)
        )
        let fact = try #require(contradictions.facts.first)
        #expect(fact.predicate == "contradicts")
        #expect(fact.asserted)
        #expect(Set(fact.receiptIDs) == [first.receiptID, second.receiptID])

        let why = try await gateway.reasoning(
            ResearchVaultReasoningQuery(kind: .why, factID: fact.id)
        )
        #expect(why.facts.map(\.id) == [fact.id])
        #expect(why.derivations.isEmpty)
        #expect(!why.truncated)

        let secondRelation = ResearchVaultReasoningRelation(
            relation: .dependsOn,
            subject: .init(receiptID: second.receiptID, findingIndex: 0),
            object: .init(receiptID: first.receiptID, findingIndex: 0)
        )
        let invalidated = try await store.loadReasoningCache(
            rulePackHash: String(repeating: "f", count: 64),
            engineVersion: "future-engine"
        )
        #expect(invalidated == nil)
        let accumulated = try await gateway.refreshReasoningShadow(
            ResearchVaultReasoningPromotionRequest(relations: [secondRelation])
        )
        #expect(accumulated.relationCount == 2)
        #expect(accumulated.baseFactCount == 6)

        let allBeforeRetraction = try await gateway.reasoning(
            ResearchVaultReasoningQuery(kind: .facts, limit: 64)
        )
        #expect(allBeforeRetraction.facts.contains(where: { $0.id == fact.id }))
        #expect(allBeforeRetraction.facts.contains(where: { $0.predicate == "dependsOn" }))

        let retracted = try await gateway.refreshReasoningShadow(
            ResearchVaultReasoningPromotionRequest(relations: [], removingFactIDs: [fact.id])
        )
        #expect(retracted.relationCount == 1)
        let allAfterRetraction = try await gateway.reasoning(
            ResearchVaultReasoningQuery(kind: .facts, limit: 64)
        )
        #expect(!allAfterRetraction.facts.contains(where: { $0.id == fact.id }))
        #expect(allAfterRetraction.facts.contains(where: { $0.predicate == "dependsOn" }))

        let directFact = try #require(allAfterRetraction.facts.first(where: {
            $0.asserted && $0.predicate == "claim"
        }))
        await #expect(throws: ResearchVaultGatewayError.invalidReasoningFact) {
            _ = try await gateway.refreshReasoningShadow(
                ResearchVaultReasoningPromotionRequest(
                    relations: [], removingFactIDs: [directFact.id]
                )
            )
        }
    }

    @Test("reasoning promotion cannot resolve unapproved or cross-scope receipts")
    func reasoningPromotionScope() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-vault-reasoning-scope-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLCipherReceiptStore(
            databaseURL: root.appendingPathComponent("vault.ccsql"),
            key: Data(repeating: 0x66, count: 32)
        )
        let authorization = VaultAuthorization(
            projectKeys: ["throttle"], maximumSensitivity: .internal
        )
        let gateway = ResearchVaultGateway(store: store, authorization: authorization)
        let approved = try Self.reasoningReceipt(
            id: "60000000-0000-4000-8000-000000000001",
            sourceID: "source-a",
            claim: "Approved"
        )
        let pending = try Self.reasoningReceipt(
            id: "60000000-0000-4000-8000-000000000002",
            sourceID: "source-b",
            claim: "Pending"
        )
        _ = try await gateway.importReceipts([approved])
        _ = try await gateway.importReceiptsForReview([pending])
        let relation = ResearchVaultReasoningRelation(
            relation: .supersedes,
            subject: .init(receiptID: approved.receiptID, findingIndex: 0),
            object: .init(receiptID: pending.receiptID, findingIndex: 0)
        )

        await #expect(throws: ResearchReceiptProjectionError.invalidFindingReference(
            .init(receiptID: pending.receiptID, findingIndex: 0)
        )) {
            _ = try await gateway.refreshReasoningShadow(
                ResearchVaultReasoningPromotionRequest(relations: [relation])
            )
        }
    }

    private static func receipt(id: String, createdAt: TimeInterval) throws -> ResearchReceipt {
        try ResearchReceipt.seal(
            receiptID: id,
            sessionID: "export-page",
            agentID: "gateway-test",
            projectKey: "throttle",
            question: "Export approved receipt",
            findings: [],
            sources: [],
            sensitivity: .internal,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }

    private static func reasoningReceipt(
        id: String,
        sourceID: String,
        claim: String
    ) throws -> ResearchReceipt {
        try ResearchReceipt.seal(
            receiptID: id,
            sessionID: "reasoning",
            agentID: "gateway-test",
            projectKey: "throttle",
            question: "Reasoning fixture",
            findings: [ResearchFinding(
                claim: claim,
                status: .verified,
                evidenceIDs: [sourceID]
            )],
            sources: [ResearchSource(
                id: sourceID,
                kind: .file,
                locator: "evidence/" + sourceID + ".md",
                observedAt: Date(timeIntervalSince1970: 1_787_832_000),
                sha256: String(repeating: "a", count: 64)
            )],
            sensitivity: .internal,
            createdAt: Date(timeIntervalSince1970: 1_787_832_000)
        )
    }
}
