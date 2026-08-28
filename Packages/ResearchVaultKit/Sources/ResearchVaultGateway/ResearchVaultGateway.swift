import CryptoKit
import Foundation
import ResearchVaultIngestion
import ResearchVaultIPCModel
import ResearchVaultModel
import ResearchVaultSQLCipher

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

/// Application-facing boundary shared by Throttle and future package clients.
/// Authorization is fixed at construction and cannot be widened per request.
public actor ResearchVaultGateway {
    private let store: SQLCipherReceiptStore
    private let authorization: VaultAuthorization

    public init(store: SQLCipherReceiptStore, authorization: VaultAuthorization) {
        self.store = store
        self.authorization = authorization
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
            switch try await store.importDocument(document, authorization: authorization) {
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
        let result = try await importReceipts(batch.receipts)
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
        let result = try await store.importReceipts(receipts, authorization: authorization)
        return ResearchVaultReceiptImportResponse(
            insertedReceipts: result.insertedReceipts,
            alreadyPresentReceipts: result.alreadyPresentReceipts
        )
    }

    /// Produces a bounded, citation-first context packet suitable for a local
    /// model or an MCP response. This method performs retrieval only; it never
    /// uploads context and never presents generated synthesis as evidence.
    public func context(
        query: String,
        limit: Int = 8,
        maximumCharacters: Int = 12_000
    ) async throws -> ResearchVaultContextBundle {
        let boundedCharacters = min(max(maximumCharacters, 256), 50_000)
        let hits = try await store.searchDocuments(
            query: query,
            limit: min(max(limit, 1), 20),
            authorization: authorization
        )
        var remaining = boundedCharacters
        var items: [ResearchVaultContextItem] = []
        var truncated = false
        for hit in hits {
            guard remaining > 0 else { truncated = true; break }
            let excerpt = String(hit.content.prefix(remaining))
            let excerptHash = SHA256.hash(data: Data(excerpt.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            if excerpt.count < hit.content.count { truncated = true }
            remaining -= excerpt.count
            items.append(ResearchVaultContextItem(
                citation: ResearchVaultCitation(
                    documentID: hit.documentID,
                    title: hit.title,
                    libraryPath: hit.libraryPath,
                    origins: hit.origins,
                    plaintextSHA256: hit.plaintextSHA256,
                    chunkOrdinal: hit.ordinal,
                    locator: hit.libraryPath + "#chunk-" + String(hit.ordinal),
                    excerptSHA256: excerptHash,
                    observedAt: hit.observedAt,
                    sourceModifiedAt: hit.sourceModifiedAt,
                    evidenceStatus: hit.evidenceStatus,
                    indexGeneration: hit.indexGeneration
                ),
                heading: hit.heading,
                excerpt: excerpt,
                score: hit.score
            ))
        }
        return ResearchVaultContextBundle(
            query: query,
            projectKeys: authorization.projectKeys.sorted(),
            maximumSensitivity: authorization.maximumSensitivity,
            items: items,
            truncated: truncated
        )
    }

    public func integrityEvidence() async throws -> SQLCipherIntegrityEvidence {
        try await store.verifyIntegrity()
    }
}
