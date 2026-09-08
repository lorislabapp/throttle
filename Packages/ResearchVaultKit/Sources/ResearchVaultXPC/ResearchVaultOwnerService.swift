import Foundation
import ResearchVaultGateway
import ResearchVaultIPCModel
import ResearchVaultModel
import ResearchVaultXPCClient

public typealias ResearchVaultProjectAdmitter = @Sendable (
    ResearchVaultProjectAdmissionRequest
) async throws -> ResearchVaultProjectAdmissionResponse

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
    private let projectAdmitter: ResearchVaultProjectAdmitter
    private let importer: ResearchVaultReceiptImporter
    private let quarantineLister: ResearchVaultQuarantineLister
    private let reviewer: ResearchVaultQuarantineReviewer
    private let exporter: ResearchVaultReceiptExporter
    private let reasoningPromoter: ResearchVaultReasoningPromoter
    private let reasoningQuerier: ResearchVaultReasoningQuerier
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        projectAdmitter: @escaping ResearchVaultProjectAdmitter = { _ in
            throw ResearchVaultProjectAdmissionError.ownerRequired
        },
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
        self.projectAdmitter = projectAdmitter
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

    public func admitProjects(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        guard request.count <= 16_384 else { reply(errorPayload(.invalidRequest)); return }
        Task {
            do {
                let input = try decoder.decode(ResearchVaultProjectAdmissionRequest.self, from: request).validated()
                reply(try encoder.encode(try await projectAdmitter(input)))
            } catch is DecodingError {
                reply(errorPayload(.invalidRequest))
            } catch is ResearchVaultIPCValidationError {
                reply(errorPayload(.invalidRequest))
            } catch ResearchVaultProjectAdmissionError.invalidProjects {
                reply(errorPayload(.invalidRequest))
            } catch {
                reply(errorPayload(.unavailable))
            }
        }
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
