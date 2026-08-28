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
                    maximumCharacters: input.maximumCharacters
                )
                reply(try encoder.encode(result))
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

public typealias ResearchVaultReceiptImporter = @Sendable (
    [ResearchReceipt]
) async throws -> ResearchVaultReceiptImportResponse

public final class ResearchVaultOwnerService: NSObject, ResearchVaultOwnerXPCProtocol,
    @unchecked Sendable {
    private let importer: ResearchVaultReceiptImporter
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(importer: @escaping ResearchVaultReceiptImporter) {
        self.importer = importer
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
        super.init()
    }

    public func importReceipts(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data) -> Void
    ) {
        guard request.count <= ResearchVaultIPCContract.maximumOwnerRequestBytes else {
            reply(errorPayload(.invalidRequest))
            return
        }
        Task {
            do {
                let input = try decoder.decode(
                    ResearchVaultReceiptImportRequest.self,
                    from: request
                ).validated()
                reply(try encoder.encode(try await importer(input.receipts)))
            } catch let error as ResearchVaultIPCValidationError {
                _ = error
                reply(errorPayload(.invalidRequest))
            } catch is DecodingError {
                reply(errorPayload(.invalidRequest))
            } catch {
                reply(errorPayload(.unavailable))
            }
        }
    }

    private func errorPayload(_ code: ResearchVaultIPCErrorPayload.Code) -> Data {
        (try? encoder.encode(ResearchVaultIPCErrorPayload(code: code))) ?? Data()
    }
}

/// Listener delegate for a query-only endpoint. In production the surrounding
/// process creates one named listener per immutable policy. Ingestion is not
/// exposed by this protocol.
public final class ResearchVaultQueryListenerDelegate: NSObject, NSXPCListenerDelegate,
    @unchecked Sendable {
    private let gateway: ResearchVaultGateway
    public let policy: ResearchVaultQueryEndpointPolicy

    public init(
        gateway: ResearchVaultGateway,
        policy: ResearchVaultQueryEndpointPolicy
    ) throws {
        try ResearchVaultCodeRequirement.validate(
            policy.authorizedClient.distributionRequirement
        )
        self.gateway = gateway
        self.policy = policy
        super.init()
    }

    public func configure(_ listener: NSXPCListener) {
        listener.setConnectionCodeSigningRequirement(
            policy.authorizedClient.distributionRequirement
        )
        listener.delegate = self
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(
            with: ResearchVaultQueryXPCProtocol.self
        )
        newConnection.exportedObject = ResearchVaultQueryService(gateway: gateway)
        newConnection.activate()
        return true
    }
}

public final class ResearchVaultOwnerListenerDelegate: NSObject, NSXPCListenerDelegate,
    @unchecked Sendable {
    private let importer: ResearchVaultReceiptImporter
    public let policy: ResearchVaultOwnerEndpointPolicy

    public init(
        policy: ResearchVaultOwnerEndpointPolicy,
        importer: @escaping ResearchVaultReceiptImporter
    ) throws {
        try ResearchVaultCodeRequirement.validate(
            policy.authorizedClient.distributionRequirement
        )
        self.policy = policy
        self.importer = importer
        super.init()
    }

    public func configure(_ listener: NSXPCListener) {
        listener.setConnectionCodeSigningRequirement(
            policy.authorizedClient.distributionRequirement
        )
        listener.delegate = self
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(
            with: ResearchVaultOwnerXPCProtocol.self
        )
        newConnection.exportedObject = ResearchVaultOwnerService(importer: importer)
        newConnection.activate()
        return true
    }
}
