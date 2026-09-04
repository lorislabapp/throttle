import Foundation
import ResearchVaultModel

public enum ReceiptImportResult: Equatable, Sendable {
    case inserted
    case alreadyPresent
}

public struct ReceiptBatchImportResult: Equatable, Sendable {
    public let insertedReceipts: Int
    public let alreadyPresentReceipts: Int

    public init(insertedReceipts: Int, alreadyPresentReceipts: Int) {
        self.insertedReceipts = insertedReceipts
        self.alreadyPresentReceipts = alreadyPresentReceipts
    }
}

public enum ReceiptStoreError: Error, Equatable, Sendable {
    case authorizationDenied
    case receiptIDConflict(String)
}

public protocol ReceiptStore: Sendable {
    func importReceipt(
        _ receipt: ResearchReceipt,
        authorization: VaultAuthorization,
        reviewState: ResearchReviewState
    ) async throws -> ReceiptImportResult

    func receipt(
        id: String,
        authorization: VaultAuthorization
    ) async throws -> ResearchReceipt?

    func receipts(authorization: VaultAuthorization) async throws -> [ResearchReceipt]
}

public actor InMemoryReceiptStore: ReceiptStore {
    private var receiptsByID: [String: ResearchReceipt] = [:]
    private var reviewStatesByID: [String: ResearchReviewState] = [:]

    public init() {}

    public func importReceipt(
        _ receipt: ResearchReceipt,
        authorization: VaultAuthorization,
        reviewState: ResearchReviewState
    ) throws -> ReceiptImportResult {
        guard authorization.permits(
            projectKey: receipt.projectKey,
            sensitivity: receipt.sensitivity
        ) else {
            throw ReceiptStoreError.authorizationDenied
        }
        try ResearchReceiptValidator.validate(receipt)

        if let existing = receiptsByID[receipt.receiptID] {
            guard existing.contentHash == receipt.contentHash else {
                throw ReceiptStoreError.receiptIDConflict(receipt.receiptID)
            }
            return .alreadyPresent
        }

        receiptsByID[receipt.receiptID] = receipt
        reviewStatesByID[receipt.receiptID] = reviewState
        return .inserted
    }

    public func receipt(
        id: String,
        authorization: VaultAuthorization
    ) throws -> ResearchReceipt? {
        guard let receipt = receiptsByID[id] else { return nil }
        guard authorization.permits(
            projectKey: receipt.projectKey,
            sensitivity: receipt.sensitivity
        ) else {
            throw ReceiptStoreError.authorizationDenied
        }
        guard reviewStatesByID[id] == .approved else { return nil }
        return receipt
    }

    public func receipts(authorization: VaultAuthorization) -> [ResearchReceipt] {
        receiptsByID.values
            .filter {
                reviewStatesByID[$0.receiptID] == .approved &&
                authorization.permits(
                    projectKey: $0.projectKey,
                    sensitivity: $0.sensitivity
                )
            }
            .sorted { $0.createdAt < $1.createdAt }
    }
}
