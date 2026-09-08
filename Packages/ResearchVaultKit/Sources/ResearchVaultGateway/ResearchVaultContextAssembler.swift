import CryptoKit
import Foundation
import ResearchVaultIngestion
import ResearchVaultIPCModel
import ResearchVaultModel
import ResearchVaultSQLCipher

enum ResearchVaultContextAssembler {
    private enum Candidate {
        case document(ResearchDocumentSearchHit)
        case receipt(ResearchReceiptSearchHit)

        var content: String {
            switch self {
            case .document(let hit): return hit.content
            case .receipt(let hit): return hit.receipt.findings[hit.findingIndex].claim
            }
        }
    }

    static func context(
        store: SQLCipherReceiptStore, authorization: VaultAuthorization,
        query: String, limit: Int, maximumCharacters: Int
    ) async throws -> ResearchVaultContextBundle {
        let limit = min(max(limit, 1), 20)
        let documents = try await store.searchDocuments(query: query, limit: limit, authorization: authorization)
        let receipts = try await store.searchReceiptDocuments(query: query, limit: limit, authorization: authorization)
        // BM25 values from separate corpora are not comparable. Alternate ranks
        // deterministically, preserving each index's order and one hit per item.
        // Qualification measures this merge; it is not a claim of higher recall.
        var candidates: [Candidate] = []
        for index in 0..<max(documents.count, receipts.count) {
            if documents.indices.contains(index) { candidates.append(.document(documents[index])) }
            if receipts.indices.contains(index) { candidates.append(.receipt(receipts[index])) }
        }
        let mixed = !documents.isEmpty && !receipts.isEmpty
        var remaining = min(max(maximumCharacters, 256), 50_000)
        var items: [ResearchVaultContextItem] = []
        var truncated = candidates.count > limit
        func bundle(_ selected: [ResearchVaultContextItem], truncated: Bool) -> ResearchVaultContextBundle {
            ResearchVaultContextBundle(
                query: query, projectKeys: authorization.projectKeys.sorted(),
                maximumSensitivity: authorization.maximumSensitivity, items: selected, truncated: truncated
            )
        }
        // Reject an oversized envelope even when no search result is available.
        _ = try bundle([], truncated: false).encodedForIPC()
        for (rank, candidate) in candidates.enumerated() {
            guard remaining > 0, items.count < limit else { truncated = true; break }
            let excerpt = String(candidate.content.prefix(remaining))
            let mergedScore = mixed ? 1.0 / Double(60 + rank + 1) : nil
            let item: ResearchVaultContextItem
            switch candidate {
            case .document(let hit): item = documentItem(hit, excerpt: excerpt, score: mergedScore)
            case .receipt(let hit): item = receiptItem(hit, excerpt: excerpt, score: mergedScore)
            }
            do {
                // Keep each citation intact. Omit an item that cannot fit, then
                // consider later candidates without consuming its text budget.
                _ = try bundle(items + [item], truncated: false).encodedForIPC()
            } catch ResearchVaultContextEncodingError.responseTooLarge {
                truncated = true
                continue
            }
            items.append(item)
            remaining -= excerpt.count
            truncated = truncated || excerpt.count < candidate.content.count
        }
        return bundle(items, truncated: truncated)
    }

    private static func documentItem(
        _ hit: ResearchDocumentSearchHit, excerpt: String, score: Double?
    ) -> ResearchVaultContextItem {
        ResearchVaultContextItem(citation: ResearchVaultCitation(
            documentID: hit.documentID, title: hit.title, libraryPath: hit.libraryPath,
            origins: hit.origins, plaintextSHA256: hit.plaintextSHA256, chunkOrdinal: hit.ordinal,
            locator: hit.libraryPath + "#chunk-" + String(hit.ordinal), excerptSHA256: hash(excerpt),
            observedAt: hit.observedAt, sourceModifiedAt: hit.sourceModifiedAt,
            evidenceStatus: hit.evidenceStatus, indexGeneration: hit.indexGeneration
        ), heading: hit.heading, excerpt: excerpt, score: score ?? hit.score)
    }

    private static func receiptItem(
        _ hit: ResearchReceiptSearchHit, excerpt: String, score: Double?
    ) -> ResearchVaultContextItem {
        let receipt = hit.receipt
        let finding = receipt.findings[hit.findingIndex]
        let sourceIDs = Set(finding.evidenceIDs)
        let sources = receipt.sources.filter { sourceIDs.contains($0.id) }
        let path = "vault-receipt/" + receipt.receiptID
        let projection = receipt.findings.map(\.claim).joined(separator: "\n\n")
        return ResearchVaultContextItem(citation: ResearchVaultCitation(
            documentID: "receipt:" + receipt.receiptID, title: receipt.question, libraryPath: path,
            origins: sources.map(\.locator), plaintextSHA256: hash(projection), chunkOrdinal: hit.findingIndex,
            locator: path + "#chunk-" + String(hit.findingIndex), excerptSHA256: hash(excerpt),
            observedAt: Date(), sourceModifiedAt: receipt.createdAt, evidenceStatus: finding.status,
            indexGeneration: "receipt-fts5-bm25-v1:" + receipt.contentHash,
            receiptProvenance: ResearchVaultReceiptProvenance(
                receiptID: receipt.receiptID, sealedContentHash: receipt.contentHash,
                findingIndex: hit.findingIndex, sources: sources
            )
        ), heading: nil, excerpt: excerpt, score: score ?? hit.score)
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
