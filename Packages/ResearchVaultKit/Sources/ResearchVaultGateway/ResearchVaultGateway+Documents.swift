import Foundation
import ResearchVaultIngestion
import ResearchVaultIPCModel
import ResearchVaultModel

public enum ResearchVaultDocumentImportError: Error, Equatable, Sendable {
    /// The service was built without a document importer (a test harness, or an
    /// older agent binary): the caller learns that rather than seeing silence.
    case unavailable
}

public extension ResearchVaultGateway {

    /// Text of documents the owner explicitly trusted (a watched folder). They
    /// enter retrieval approved, exactly like a DeepSearsh snapshot: the trust
    /// decision was made when the folder was designated.
    func importDocuments(
        _ documents: [ResearchVaultDocumentPayload]
    ) async throws -> ResearchVaultDocumentImportResponse {
        var inserted = 0
        var present = 0
        var chunks = 0
        for payload in documents {
            let candidate = ResearchDocumentCandidate(
                documentID: payload.documentID,
                title: payload.title,
                projectKey: payload.projectKey,
                category: payload.category,
                libraryPath: payload.libraryPath,
                origins: payload.origins,
                content: payload.content,
                plaintextSHA256: payload.plaintextSHA256,
                byteCount: payload.byteCount,
                modifiedAt: payload.modifiedAt,
                sensitivity: ResearchSensitivity(rawValue: payload.sensitivity) ?? .confidential
            )
            switch try await store.importDocument(candidate, authorization: authorization,
                                                  reviewState: .approved) {
            case let .inserted(chunkCount):
                inserted += 1
                chunks += chunkCount
            case .alreadyPresent:
                present += 1
            }
        }
        return ResearchVaultDocumentImportResponse(
            insertedDocuments: inserted, alreadyPresentDocuments: present, insertedChunks: chunks
        )
    }
}
