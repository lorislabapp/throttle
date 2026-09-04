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
public typealias ResearchVaultQuarantineLister = @Sendable () async throws
    -> ResearchVaultQuarantineListResponse
public typealias ResearchVaultQuarantineReviewer = @Sendable (
    ResearchVaultReviewRequest
) async throws -> ResearchVaultReviewResponse
public typealias ResearchVaultReceiptExporter = @Sendable (
    ResearchVaultReceiptExportRequest
) async throws -> ResearchVaultReceiptExportResponse
public typealias ResearchVaultReasoningPromoter = @Sendable (
    ResearchVaultReasoningPromotionRequest
) async throws -> ResearchVaultReasoningRefreshResponse
public typealias ResearchVaultReasoningQuerier = @Sendable (
    ResearchVaultReasoningQuery
) async throws -> ResearchVaultReasoningQueryResponse

public final class ResearchVaultOwnerService: NSObject, ResearchVaultOwnerXPCProtocol,
    @unchecked Sendable {
    private let importer: ResearchVaultReceiptImporter
    private let quarantineLister: ResearchVaultQuarantineLister
    private let reviewer: ResearchVaultQuarantineReviewer
    private let exporter: ResearchVaultReceiptExporter
    private let reasoningPromoter: ResearchVaultReasoningPromoter
    private let reasoningQuerier: ResearchVaultReasoningQuerier
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        importer: @escaping ResearchVaultReceiptImporter,
        quarantineLister: @escaping ResearchVaultQuarantineLister,
        reviewer: @escaping ResearchVaultQuarantineReviewer,
        exporter: @escaping ResearchVaultReceiptExporter,
        reasoningPromoter: @escaping ResearchVaultReasoningPromoter = { _ in
            throw ResearchVaultGatewayError.reasoningUnavailable
        },
        reasoningQuerier: @escaping ResearchVaultReasoningQuerier = { _ in
            throw ResearchVaultGatewayError.reasoningUnavailable
        }
    ) {
        self.importer = importer
        self.quarantineLister = quarantineLister
        self.reviewer = reviewer
        self.exporter = exporter
        self.reasoningPromoter = reasoningPromoter
        self.reasoningQuerier = reasoningQuerier
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

    public func listQuarantine(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data) -> Void
    ) {
        guard request.count <= 512 else {
            reply(errorPayload(.invalidRequest))
            return
        }
        Task {
            do {
                _ = try decoder.decode(
                    ResearchVaultQuarantineListRequest.self,
                    from: request
                ).validated()
                reply(try encoder.encode(try await quarantineLister()))
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

    public func reviewQuarantine(
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
                    ResearchVaultReviewRequest.self,
                    from: request
                ).validated()
                reply(try encoder.encode(try await reviewer(input)))
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

    public func exportReceipts(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data) -> Void
    ) {
        guard request.count <= 1_024 else {
            reply(errorPayload(.invalidRequest))
            return
        }
        Task {
            do {
                let input = try decoder.decode(
                    ResearchVaultReceiptExportRequest.self,
                    from: request
                ).validated()
                reply(try encoder.encode(try await exporter(input)))
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

    public func promoteReasoning(
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
                    ResearchVaultReasoningPromotionRequest.self,
                    from: request
                ).validated()
                reply(try encoder.encode(try await reasoningPromoter(input)))
            } catch is ResearchVaultIPCValidationError {
                reply(errorPayload(.invalidRequest))
            } catch is DecodingError {
                reply(errorPayload(.invalidRequest))
            } catch {
                reply(errorPayload(.unavailable))
            }
        }
    }

    public func queryReasoning(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data) -> Void
    ) {
        guard request.count <= 1_024 else {
            reply(errorPayload(.invalidRequest))
            return
        }
        Task {
            do {
                let input = try decoder.decode(
                    ResearchVaultReasoningQuery.self,
                    from: request
                ).validated()
                reply(try encoder.encode(try await reasoningQuerier(input)))
            } catch is ResearchVaultIPCValidationError {
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
    private let quarantineLister: ResearchVaultQuarantineLister
    private let reviewer: ResearchVaultQuarantineReviewer
    private let exporter: ResearchVaultReceiptExporter
    private let reasoningPromoter: ResearchVaultReasoningPromoter
    private let reasoningQuerier: ResearchVaultReasoningQuerier
    public let policy: ResearchVaultOwnerEndpointPolicy

    public init(
        policy: ResearchVaultOwnerEndpointPolicy,
        importer: @escaping ResearchVaultReceiptImporter,
        quarantineLister: @escaping ResearchVaultQuarantineLister,
        reviewer: @escaping ResearchVaultQuarantineReviewer,
        exporter: @escaping ResearchVaultReceiptExporter,
        reasoningPromoter: @escaping ResearchVaultReasoningPromoter,
        reasoningQuerier: @escaping ResearchVaultReasoningQuerier
    ) throws {
        try ResearchVaultCodeRequirement.validate(
            policy.authorizedClient.distributionRequirement
        )
        self.policy = policy
        self.importer = importer
        self.quarantineLister = quarantineLister
        self.reviewer = reviewer
        self.exporter = exporter
        self.reasoningPromoter = reasoningPromoter
        self.reasoningQuerier = reasoningQuerier
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
        newConnection.exportedObject = ResearchVaultOwnerService(
            importer: importer,
            quarantineLister: quarantineLister,
            reviewer: reviewer,
            exporter: exporter,
            reasoningPromoter: reasoningPromoter,
            reasoningQuerier: reasoningQuerier
        )
        newConnection.activate()
        return true
    }
}
