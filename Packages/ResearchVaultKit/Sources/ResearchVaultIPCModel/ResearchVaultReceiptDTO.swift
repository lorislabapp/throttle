import Foundation
import ResearchVaultModel

/// Administrative input is content-only: no path, key, project grant or
/// sensitivity ceiling can be selected by the caller. Each receipt still
/// carries its own provenance and classification, which the endpoint's
/// immutable authorization validates server-side.
public struct ResearchVaultReceiptImportRequest: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let receipts: [ResearchReceipt]

    public init(
        contractVersion: Int = ResearchVaultIPCContract.currentVersion,
        receipts: [ResearchReceipt]
    ) {
        self.contractVersion = contractVersion
        self.receipts = receipts
    }

    public func validated() throws -> Self {
        guard contractVersion == ResearchVaultIPCContract.currentVersion else {
            throw ResearchVaultIPCValidationError.unsupportedContractVersion(contractVersion)
        }
        guard !receipts.isEmpty,
              receipts.count <= ResearchVaultIPCContract.maximumReceiptsPerRequest else {
            throw ResearchVaultIPCValidationError.invalidReceiptBatch
        }
        do {
            for receipt in receipts {
                try ResearchReceiptValidator.validate(receipt)
            }
        } catch {
            throw ResearchVaultIPCValidationError.invalidReceipt
        }
        return self
    }
}

public struct ResearchVaultReceiptImportResponse: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let insertedReceipts: Int
    public let alreadyPresentReceipts: Int

    public init(
        contractVersion: Int = ResearchVaultIPCContract.currentVersion,
        insertedReceipts: Int,
        alreadyPresentReceipts: Int
    ) {
        self.contractVersion = contractVersion
        self.insertedReceipts = insertedReceipts
        self.alreadyPresentReceipts = alreadyPresentReceipts
    }
}

public struct ResearchVaultQuarantineItem: Codable, Equatable, Sendable {
    public let receiptID: String
    public let projectKey: String
    public let question: String
    public let sensitivity: String
    public let createdAtMS: Int64
    public let sourceCount: Int
    public let firstSourceLocator: String?

    public init(
        receiptID: String,
        projectKey: String,
        question: String,
        sensitivity: String,
        createdAtMS: Int64,
        sourceCount: Int,
        firstSourceLocator: String?
    ) {
        self.receiptID = receiptID
        self.projectKey = projectKey
        self.question = question
        self.sensitivity = sensitivity
        self.createdAtMS = createdAtMS
        self.sourceCount = sourceCount
        self.firstSourceLocator = firstSourceLocator
    }
}

public struct ResearchVaultQuarantineListRequest: Codable, Equatable, Sendable {
    public let contractVersion: Int

    public init(contractVersion: Int = ResearchVaultIPCContract.currentVersion) {
        self.contractVersion = contractVersion
    }

    public func validated() throws -> Self {
        guard contractVersion == ResearchVaultIPCContract.currentVersion else {
            throw ResearchVaultIPCValidationError.unsupportedContractVersion(contractVersion)
        }
        return self
    }
}

public struct ResearchVaultQuarantineListResponse: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let items: [ResearchVaultQuarantineItem]

    public init(
        contractVersion: Int = ResearchVaultIPCContract.currentVersion,
        items: [ResearchVaultQuarantineItem]
    ) {
        self.contractVersion = contractVersion
        self.items = items
    }
}

public struct ResearchVaultReviewRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case approve
        case reject
    }

    public let contractVersion: Int
    public let action: Action
    public let receiptIDs: [String]

    public init(
        contractVersion: Int = ResearchVaultIPCContract.currentVersion,
        action: Action,
        receiptIDs: [String]
    ) {
        self.contractVersion = contractVersion
        self.action = action
        self.receiptIDs = receiptIDs
    }

    public func validated() throws -> Self {
        guard contractVersion == ResearchVaultIPCContract.currentVersion else {
            throw ResearchVaultIPCValidationError.unsupportedContractVersion(contractVersion)
        }
        guard !receiptIDs.isEmpty,
              receiptIDs.count <= ResearchVaultIPCContract.maximumReceiptsPerRequest,
              Set(receiptIDs).count == receiptIDs.count,
              receiptIDs.allSatisfy({ id in
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && id.utf8.count <= 256
              }) else {
            throw ResearchVaultIPCValidationError.invalidReviewBatch
        }
        return self
    }
}

public struct ResearchVaultReviewResponse: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let processed: Int

    public init(
        contractVersion: Int = ResearchVaultIPCContract.currentVersion,
        processed: Int
    ) {
        self.contractVersion = contractVersion
        self.processed = processed
    }
}

public struct ResearchVaultReceiptExportRequest: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let afterReceiptID: String?
    public let limit: Int

    public init(
        contractVersion: Int = ResearchVaultIPCContract.currentVersion,
        afterReceiptID: String? = nil,
        limit: Int = 8
    ) {
        self.contractVersion = contractVersion
        self.afterReceiptID = afterReceiptID
        self.limit = limit
    }

    public func validated() throws -> Self {
        guard contractVersion == ResearchVaultIPCContract.currentVersion else {
            throw ResearchVaultIPCValidationError.unsupportedContractVersion(contractVersion)
        }
        guard (1 ... ResearchVaultIPCContract.maximumReceiptsPerRequest).contains(limit),
              afterReceiptID.map({ UUID(uuidString: $0) != nil }) ?? true else {
            throw ResearchVaultIPCValidationError.invalidExportPage
        }
        return self
    }
}

public struct ResearchVaultReceiptExportResponse: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let receipts: [ResearchReceipt]
    public let nextReceiptID: String?

    public init(
        contractVersion: Int = ResearchVaultIPCContract.currentVersion,
        receipts: [ResearchReceipt],
        nextReceiptID: String?
    ) {
        self.contractVersion = contractVersion
        self.receipts = receipts
        self.nextReceiptID = nextReceiptID
    }
}
