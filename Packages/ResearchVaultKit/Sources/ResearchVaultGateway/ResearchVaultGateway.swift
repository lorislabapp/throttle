import CryptoKit
import Foundation
import ResearchVaultIngestion
import ResearchVaultIPCModel
import ResearchVaultModel
import ResearchVaultReasoning
@_spi(ReasoningPersistence) @_spi(OwnerProjectAdministration) import ResearchVaultSQLCipher

public struct ResearchVaultSnapshotImportEvidence: Codable, Equatable, Sendable {
    public let snapshotSHA256: String
    public let scannedEntries: Int
    public let insertedDocuments: Int
    public let alreadyPresentDocuments: Int
    public let insertedChunks: Int
}

public struct ResearchVaultInboxImportEvidence: Codable, Equatable, Sendable {
    public let snapshotSHA256: String
    public let insertedReceipts: Int
    public let alreadyPresentReceipts: Int
}

public struct ResearchVaultToolDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: String
}

public enum ResearchVaultGatewayError: Error, Equatable, Sendable {
    case reviewTargetUnavailable
    case exportCursorUnavailable
    case receiptUnavailable
    case sourceUnavailable
    case reasoningUnavailable
    case invalidReasoningFact
}

public struct ResearchVaultSourceResource: Codable, Equatable, Sendable {
    public let receiptID: String
    public let projectKey: String
    public let question: String
    public let sensitivity: ResearchSensitivity
    public let source: ResearchSource
}

/// Application-facing boundary shared by Throttle and future package clients.
/// Ordinary gateways have a fixed grant. The owner gateway can admit projects
/// through its separate authenticated operation; receipts never widen grants.
public actor ResearchVaultGateway {
    private let store: SQLCipherReceiptStore
    private var authorization: VaultAuthorization
    private let permitsProjectAdmission: Bool
    private var lastReasoningChangeSet: ReasoningChangeSet?

    private struct ReasoningChangeSet: Sendable {
        let generation: Int64
        let added: [String]
        let removed: [String]
        let updated: [String]
    }

    public init(store: SQLCipherReceiptStore, authorization: VaultAuthorization) {
        self.store = store
        self.authorization = authorization
        self.permitsProjectAdmission = false
    }

    private init(ownerStore: SQLCipherReceiptStore, authorization: VaultAuthorization) {
        self.store = ownerStore
        self.authorization = authorization
        self.permitsProjectAdmission = true
    }

    /// Production uses this factory only for Throttle's authenticated owner and
    /// first-party query endpoints. No third-party endpoint receives this grant.
    public static func owner(
        store: SQLCipherReceiptStore,
        baseline: VaultAuthorization
    ) async throws -> ResearchVaultGateway {
        let projects = try await store.ownerProjectKeys().union(baseline.projectKeys)
        return ResearchVaultGateway(ownerStore: store, authorization: VaultAuthorization(
            projectKeys: projects, maximumSensitivity: baseline.maximumSensitivity
        ))
    }

    public func admitProjects(
        _ request: ResearchVaultProjectAdmissionRequest
    ) async throws -> ResearchVaultProjectAdmissionResponse {
        guard permitsProjectAdmission else { throw ResearchVaultProjectAdmissionError.ownerRequired }
        let request = try request.validated()
        let projects = try await store.admitOwnerProjects(Set(request.projectKeys))
        // Actor reentrancy cannot replace a later concurrent admission with an
        // older returned snapshot: the in-memory owner grant only grows here.
        authorization = VaultAuthorization(
            projectKeys: authorization.projectKeys.union(projects),
            maximumSensitivity: authorization.maximumSensitivity
        )
        return ResearchVaultProjectAdmissionResponse(projectKeys: request.projectKeys.sorted())
    }

    public static let toolDefinitions = [
        ResearchVaultToolDefinition(
            name: "research_vault_search",
            description: "Search the authorized local encrypted research vault and return provenance-bound excerpts.",
            inputSchema: #"{"type":"object","additionalProperties":false,"required":["query"],"properties":{"query":{"type":"string","minLength":1,"maxLength":4096},"limit":{"type":"integer","minimum":1,"maximum":20},"maximumCharacters":{"type":"integer","minimum":256,"maximum":50000}}}"#
        ),
        ResearchVaultToolDefinition(
            name: "research_vault_health",
            description: "Return secret-free encrypted-store integrity evidence.",
            inputSchema: #"{"type":"object","additionalProperties":false,"properties":{}}"#
        ),
    ]

    public func importDeepSearshSnapshot(root: URL) async throws -> ResearchVaultSnapshotImportEvidence {
        let batch = try DeepSearshCatalogImporter(root: root)
            .load(projectKeys: authorization.projectKeys)
        var inserted = 0
        var present = 0
        var chunks = 0
        for document in batch.documents {
            switch try await store.importDocument(
                document,
                authorization: authorization,
                reviewState: .approved
            ) {
            case let .inserted(chunkCount):
                inserted += 1
                chunks += chunkCount
            case .alreadyPresent:
                present += 1
            }
        }
        return ResearchVaultSnapshotImportEvidence(
            snapshotSHA256: batch.evidence.catalogSHA256,
            scannedEntries: batch.evidence.scannedEntries,
            insertedDocuments: inserted,
            alreadyPresentDocuments: present,
            insertedChunks: chunks
        )
    }

    public func importReceiptInbox(root: URL) async throws -> ResearchVaultInboxImportEvidence {
        let batch = try ResearchReceiptInbox(root: root).scan()
        let result = try await importReceiptsForReview(batch.receipts)
        return ResearchVaultInboxImportEvidence(
            snapshotSHA256: batch.snapshotSHA256,
            insertedReceipts: result.insertedReceipts,
            alreadyPresentReceipts: result.alreadyPresentReceipts
        )
    }

    /// Imports already-sealed receipts received through the owner-only IPC
    /// role. The endpoint grant remains authoritative; receipt metadata cannot
    /// widen it and a single unauthorized receipt fails the batch.
    public func importReceipts(
        _ receipts: [ResearchReceipt]
    ) async throws -> ResearchVaultReceiptImportResponse {
        let result = try await store.importReceipts(
            receipts,
            authorization: authorization,
            reviewState: .approved
        )
        return ResearchVaultReceiptImportResponse(
            insertedReceipts: result.insertedReceipts,
            alreadyPresentReceipts: result.alreadyPresentReceipts
        )
    }

    /// Owner-facing intake is deliberately separate from trusted bootstrap
    /// imports. New material cannot enter retrieval until the owner reviews it.
    public func importReceiptsForReview(
        _ receipts: [ResearchReceipt]
    ) async throws -> ResearchVaultReceiptImportResponse {
        let result = try await store.importReceipts(
            receipts,
            authorization: authorization,
            reviewState: .quarantined
        )
        return ResearchVaultReceiptImportResponse(
            insertedReceipts: result.insertedReceipts,
            alreadyPresentReceipts: result.alreadyPresentReceipts
        )
    }

    public func approvedReceipt(id: String) async throws -> ResearchReceipt {
        guard let receipt = try await store.receipt(id: id, authorization: authorization) else {
            throw ResearchVaultGatewayError.receiptUnavailable
        }
        return receipt
    }

    public func approvedSource(
        receiptID: String,
        sourceID: String
    ) async throws -> ResearchVaultSourceResource {
        let receipt = try await approvedReceipt(id: receiptID)
        guard let source = receipt.sources.first(where: { $0.id == sourceID }) else {
            throw ResearchVaultGatewayError.sourceUnavailable
        }
        return ResearchVaultSourceResource(
            receiptID: receipt.receiptID,
            projectKey: receipt.projectKey,
            question: receipt.question,
            sensitivity: receipt.sensitivity,
            source: source
        )
    }

    public func approvedReceipts() async throws -> [ResearchReceipt] {
        try await store.receipts(authorization: authorization)
    }

    /// Owner-only promotion and shadow refresh. The request cannot supply a
    /// project, sensitivity ceiling or rule pack. Existing BM25 responses are
    /// untouched; reasoning is persisted as a separately versioned cache.
    public func refreshReasoningShadow(
        _ unvalidatedRequest: ResearchVaultReasoningPromotionRequest
    ) async throws -> ResearchVaultReasoningRefreshResponse {
        let request = try unvalidatedRequest.validated()
        let receipts = try await store.receipts(authorization: authorization)
        let projector = ResearchReceiptFactProjector()
        let rules = Self.reasoningRules
        let rulePackHash = try Self.reasoningRulePackHash()
        let oldSnapshot = try await loadReasoningSnapshot(
            rulePackHash: rulePackHash,
            rules: rules
        )
        let explicitPredicates = Set(ResearchVaultReasoningRelationKind.allCases.map(\.rawValue))
        let existingRelations = try await store.reasoningBaseFacts(
            authorization: authorization
        ).filter {
            explicitPredicates.contains($0.predicate)
        }
        let existingRelationIDs = Set(existingRelations.map(\.id))
        guard Set(request.removingFactIDs).isSubset(of: existingRelationIDs) else {
            throw ResearchVaultGatewayError.invalidReasoningFact
        }

        var baseFacts = try receipts.flatMap {
            try projector.directFacts(from: $0, reviewState: .approved)
        }
        let candidates = request.relations.map { relation in
            let kind: ResearchRelationKind = switch relation.relation {
            case .contradicts: .contradicts
            case .supersedes: .supersedes
            case .dependsOn: .dependsOn
            }
            return ResearchRelationCandidate(
                relation: kind,
                subject: ResearchClaimReference(
                    receiptID: relation.subject.receiptID,
                    findingIndex: relation.subject.findingIndex
                ),
                object: ResearchClaimReference(
                    receiptID: relation.object.receiptID,
                    findingIndex: relation.object.findingIndex
                ),
                validFrom: relation.validFrom,
                validUntil: relation.validUntil
            )
        }
        baseFacts += try projector.promotedFacts(
            candidates: candidates,
            approvedReceipts: receipts
        )
        baseFacts += existingRelations.filter { !request.removingFactIDs.contains($0.id) }
        // Canonicalize duplicate promotions and merge their evidence before the
        // SQL transaction, whose fact IDs are unique by construction.
        baseFacts = try ResearchReasoningEngine()
            .evaluate(baseFacts: baseFacts, rules: [])
            .baseFacts

        var generation: Int64 = try await store.activeReasoningGeneration()
        for projectKey in authorization.projectKeys.sorted() {
            generation = try await store.replaceReasoningBaseFacts(
                baseFacts.filter { $0.projectKey == projectKey },
                forProject: projectKey,
                authorization: authorization
            )
        }
        let snapshot = try ResearchReasoningEngine().evaluate(
            baseFacts: baseFacts,
            rules: rules
        )
        try await store.persistReasoningCache(
            snapshot,
            baseGeneration: generation,
            rulePackHash: rulePackHash,
            engineVersion: Self.reasoningEngineVersion
        )
        let delta: ResearchReasoningDelta?
        if let oldSnapshot {
            delta = ResearchReasoningEngine().whatChanged(from: oldSnapshot, to: snapshot)
        } else {
            delta = nil
        }
        lastReasoningChangeSet = ReasoningChangeSet(
            generation: generation,
            added: delta?.addedFactIDs ?? snapshot.facts.map(\.id).sorted(),
            removed: delta?.removedFactIDs ?? [],
            updated: delta?.updatedFactIDs ?? []
        )
        return ResearchVaultReasoningRefreshResponse(
            generation: generation,
            baseFactCount: snapshot.baseFactIDs.count,
            derivedFactCount: snapshot.facts.count - snapshot.baseFactIDs.count,
            relationCount: baseFacts.count(where: { explicitPredicates.contains($0.predicate) }),
            shadowMode: true
        )
    }

    public func reasoning(
        _ unvalidatedQuery: ResearchVaultReasoningQuery
    ) async throws -> ResearchVaultReasoningQueryResponse {
        let query = try unvalidatedQuery.validated()
        let rules = Self.reasoningRules
        let rulePackHash = try Self.reasoningRulePackHash()
        guard let snapshot = try await loadReasoningSnapshot(
            rulePackHash: rulePackHash,
            rules: rules
        ) else {
            throw ResearchVaultGatewayError.reasoningUnavailable
        }
        let generation = try await store.activeReasoningGeneration()
        switch query.kind {
        case .facts:
            return makeReasoningResponse(
                kind: query.kind,
                generation: generation,
                facts: Array(snapshot.facts.prefix(query.limit)),
                derivations: [],
                snapshot: snapshot,
                truncated: snapshot.facts.count > query.limit
            )
        case .why:
            guard let factID = query.factID else {
                throw ResearchVaultGatewayError.invalidReasoningFact
            }
            let proof = try ResearchReasoningEngine().why(factID: factID, in: snapshot)
            let facts = Array(proof.facts.prefix(query.limit))
            let factIDs = Set(facts.map(\.id))
            return makeReasoningResponse(
                kind: query.kind,
                generation: generation,
                facts: facts,
                derivations: proof.derivations.filter {
                    factIDs.contains($0.conclusionFactID)
                        && $0.premiseFactIDs.allSatisfy(factIDs.contains)
                },
                snapshot: snapshot,
                truncated: proof.truncated || proof.facts.count > query.limit
            )
        case .impacted:
            guard let factID = query.factID, snapshot.baseFactIDs.contains(factID) else {
                throw ResearchVaultGatewayError.invalidReasoningFact
            }
            let impacted = try ResearchReasoningEngine().impactedFacts(
                in: snapshot,
                removingBaseFactIDs: [factID]
            )
            return makeReasoningResponse(
                kind: query.kind,
                generation: generation,
                facts: Array(impacted.prefix(query.limit)),
                derivations: [],
                snapshot: snapshot,
                truncated: impacted.count > query.limit
            )
        case .whatChanged:
            let change = lastReasoningChangeSet
            return ResearchVaultReasoningQueryResponse(
                kind: query.kind,
                generation: generation,
                facts: [],
                derivations: [],
                addedFactIDs: Array((change?.added ?? []).prefix(query.limit)),
                removedFactIDs: Array((change?.removed ?? []).prefix(query.limit)),
                updatedFactIDs: Array((change?.updated ?? []).prefix(query.limit)),
                truncated: (change?.added.count ?? 0) > query.limit
                    || (change?.removed.count ?? 0) > query.limit
                    || (change?.updated.count ?? 0) > query.limit
            )
        case .contradictions:
            let facts = snapshot.facts(predicate: "contradicts")
            return makeReasoningResponse(
                kind: query.kind,
                generation: generation,
                facts: Array(facts.prefix(query.limit)),
                derivations: [],
                snapshot: snapshot,
                truncated: facts.count > query.limit
            )
        }
    }

    public func quarantine() async throws -> ResearchVaultQuarantineListResponse {
        let summaries = try await store.quarantinedReceipts(authorization: authorization)
        return ResearchVaultQuarantineListResponse(
            items: summaries.map { summary in
                ResearchVaultQuarantineItem(
                    receiptID: summary.receiptID,
                    projectKey: summary.projectKey,
                    question: summary.question,
                    sensitivity: summary.sensitivity.rawValue,
                    createdAtMS: Int64(summary.createdAt.timeIntervalSince1970 * 1_000),
                    sourceCount: summary.sourceCount,
                    firstSourceLocator: summary.firstSourceLocator
                )
            }
        )
    }

    public func review(
        _ request: ResearchVaultReviewRequest
    ) async throws -> ResearchVaultReviewResponse {
        let pending = try await store.quarantinedReceipts(authorization: authorization)
        let permittedIDs = Set(pending.map(\.receiptID))
        guard request.receiptIDs.allSatisfy(permittedIDs.contains) else {
            throw ResearchVaultGatewayError.reviewTargetUnavailable
        }
        let processed: Int
        switch request.action {
        case .approve:
            processed = try await store.approveReceipts(ids: request.receiptIDs)
        case .reject:
            processed = try await store.rejectReceipts(ids: request.receiptIDs)
        }
        return ResearchVaultReviewResponse(processed: processed)
    }

    public func exportApprovedReceipts(
        _ unvalidatedRequest: ResearchVaultReceiptExportRequest
    ) async throws -> ResearchVaultReceiptExportResponse {
        let request = try unvalidatedRequest.validated()
        let approved = try await store.receipts(authorization: authorization)
        let start: Int
        if let cursor = request.afterReceiptID {
            guard let index = approved.firstIndex(where: { $0.receiptID == cursor }) else {
                throw ResearchVaultGatewayError.exportCursorUnavailable
            }
            start = approved.index(after: index)
        } else {
            start = approved.startIndex
        }
        let page = Array(approved.dropFirst(start).prefix(request.limit))
        let hasMore = start + page.count < approved.count
        return ResearchVaultReceiptExportResponse(
            receipts: page,
            nextReceiptID: hasMore ? page.last?.receiptID : nil
        )
    }

    /// Produces a bounded, citation-first context packet suitable for a local
    /// model or an MCP response. This method performs retrieval only; it never
    /// uploads context and never presents generated synthesis as evidence.
    public func context(
        query: String,
        limit: Int = 8,
        maximumCharacters: Int = 12_000,
        projectKeys: [String]? = nil
    ) async throws -> ResearchVaultContextBundle {
        let scopedAuthorization = VaultAuthorization(
            projectKeys: projectKeys.map { authorization.projectKeys.intersection($0) } ?? authorization.projectKeys,
            maximumSensitivity: authorization.maximumSensitivity
        )
        return try await ResearchVaultContextAssembler.context(
            store: store, authorization: scopedAuthorization, query: query,
            limit: limit, maximumCharacters: maximumCharacters
        )
    }

    public func integrityEvidence() async throws -> SQLCipherIntegrityEvidence {
        try await store.verifyIntegrity()
    }

    private func loadReasoningSnapshot(
        rulePackHash: String,
        rules: [ResearchRule]
    ) async throws -> ResearchReasoningSnapshot? {
        guard let cache = try await store.loadReasoningCache(
            rulePackHash: rulePackHash,
            engineVersion: Self.reasoningEngineVersion
        ) else { return nil }
        return try ResearchReasoningEngine().evaluate(baseFacts: cache.baseFacts, rules: rules)
    }

    private func makeReasoningResponse(
        kind: ResearchVaultReasoningQueryKind,
        generation: Int64,
        facts: [ResearchFact],
        derivations: [ResearchDerivation],
        snapshot: ResearchReasoningSnapshot,
        truncated: Bool
    ) -> ResearchVaultReasoningQueryResponse {
        ResearchVaultReasoningQueryResponse(
            kind: kind,
            generation: generation,
            facts: facts.map { fact in
                ResearchVaultReasoningFactDTO(
                    id: fact.id,
                    predicate: fact.predicate,
                    arguments: fact.arguments,
                    projectKey: fact.projectKey,
                    sensitivity: fact.sensitivity,
                    asserted: snapshot.baseFactIDs.contains(fact.id),
                    receiptIDs: fact.sourceReceiptIDs,
                    sourceIDs: fact.evidenceIDs
                )
            },
            derivations: derivations.map {
                ResearchVaultReasoningDerivationDTO(
                    conclusionFactID: $0.conclusionFactID,
                    ruleID: $0.ruleID,
                    premiseFactIDs: $0.premiseFactIDs
                )
            },
            truncated: truncated
        )
    }

    private static let reasoningEngineVersion = "research-vault-reasoning-1"

    private static let reasoningRules: [ResearchRule] = [
        ResearchRule(
            id: "impact-dependency",
            head: ResearchAtom(
                predicate: "impacted",
                terms: [.variable("subject"), .variable("object")]
            ),
            body: [ResearchAtom(
                predicate: "dependsOn",
                terms: [.variable("subject"), .variable("object")]
            )]
        ),
        ResearchRule(
            id: "impact-supersession",
            head: ResearchAtom(
                predicate: "impacted",
                terms: [.variable("subject"), .variable("object")]
            ),
            body: [ResearchAtom(
                predicate: "supersedes",
                terms: [.variable("subject"), .variable("object")]
            )]
        ),
        ResearchRule(
            id: "impact-transitive",
            head: ResearchAtom(
                predicate: "impacted",
                terms: [.variable("subject"), .variable("tail")]
            ),
            body: [
                ResearchAtom(
                    predicate: "impacted",
                    terms: [.variable("subject"), .variable("middle")]
                ),
                ResearchAtom(
                    predicate: "dependsOn",
                    terms: [.variable("middle"), .variable("tail")]
                ),
            ]
        ),
    ]

    private static func reasoningRulePackHash() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(reasoningRules))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
