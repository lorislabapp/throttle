import Foundation
import ResearchVaultGateway
import ResearchVaultIPCModel
import ResearchVaultModel
import ResearchVaultXPCClient

public final class ResearchVaultQueryService: NSObject, ResearchVaultQueryXPCProtocol,
    @unchecked Sendable {
    private let gateway: ResearchVaultGateway
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(gateway: ResearchVaultGateway) {
        self.gateway = gateway
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
        super.init()
    }

    public func search(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data) -> Void
    ) {
        guard request.count <= ResearchVaultIPCContract.maximumQueryBytes + 512 else {
            reply(errorPayload(.invalidRequest))
            return
        }
        Task {
            do {
                let input = try decoder.decode(ResearchVaultSearchRequest.self, from: request)
                    .validated()
                let result = try await gateway.context(
                    query: input.query,
                    limit: input.limit,
                    maximumCharacters: input.maximumCharacters,
                    projectKeys: input.projectKeys
                )
                reply(try result.encodedForIPC())
            } catch let error as ResearchVaultIPCValidationError {
                _ = error
                reply(errorPayload(.invalidRequest))
            } catch {
                reply(errorPayload(.unavailable))
            }
        }
    }

    public func health(withReply reply: @escaping @Sendable (Data) -> Void) {
        Task {
            do {
                let evidence = try await gateway.integrityEvidence()
                reply(try encoder.encode(ResearchVaultHealthResponse(
                    schemaVersion: evidence.schemaVersion,
                    cipherVersion: evidence.cipherVersion,
                    receiptCount: evidence.receiptCount,
                    documentCount: evidence.documentCount,
                    chunkCount: evidence.chunkCount,
                    quickCheckPassed: evidence.quickCheckPassed,
                    cipherIntegrityPassed: evidence.cipherIntegrityPassed,
                    foreignKeysPassed: evidence.foreignKeysPassed
                )))
            } catch {
                reply(errorPayload(.unavailable))
            }
        }
    }

    private func errorPayload(_ code: ResearchVaultIPCErrorPayload.Code) -> Data {
        (try? encoder.encode(ResearchVaultIPCErrorPayload(code: code))) ?? Data()
    }
}
