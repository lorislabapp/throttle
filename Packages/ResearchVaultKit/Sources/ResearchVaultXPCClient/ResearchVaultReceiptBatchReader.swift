import Foundation
import ResearchVaultIPCModel
import ResearchVaultModel

public enum ResearchVaultReceiptBatchReaderError: Error, Equatable, Sendable {
    case tooManyReceipts
    case entryNotRegularFile(String)
    case entryTooLarge(String)
    case invalidReceipt(String)
    case duplicateReceiptID(String)
    case requestTooLarge
}

/// Reads only canonical, sealed receipt files from a user-authorized folder.
/// Bookmark acquisition and security-scope lifetime remain the app's job; this
/// type is pure client-side validation and has no SQLCipher or service access.
public struct ResearchVaultReceiptBatchReader: Sendable {
    public static let fileSuffix = ".research-receipt.json"

    private let maximumReceiptCount: Int
    private let maximumReceiptBytes: Int
    private let maximumRequestBytes: Int

    public init(
        maximumReceiptCount: Int = ResearchVaultIPCContract.maximumReceiptsPerRequest,
        maximumReceiptBytes: Int = ResearchVaultIPCContract.maximumOwnerRequestBytes,
        maximumRequestBytes: Int = ResearchVaultIPCContract.maximumOwnerRequestBytes
    ) {
        self.maximumReceiptCount = maximumReceiptCount
        self.maximumReceiptBytes = maximumReceiptBytes
        self.maximumRequestBytes = maximumRequestBytes
    }

    public func load(from folder: URL) throws -> [ResearchReceipt] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let files = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
        ).filter { $0.lastPathComponent.hasSuffix(Self.fileSuffix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count <= maximumReceiptCount else {
            throw ResearchVaultReceiptBatchReaderError.tooManyReceipts
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var seen = Set<String>()
        let receipts = try files.map { file -> ResearchReceipt in
            let name = file.lastPathComponent
            let values = try file.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ResearchVaultReceiptBatchReaderError.entryNotRegularFile(name)
            }
            guard let expectedSize = values.fileSize,
                  expectedSize > 0,
                  expectedSize <= maximumReceiptBytes else {
                throw ResearchVaultReceiptBatchReaderError.entryTooLarge(name)
            }
            let data = try Data(contentsOf: file, options: [.mappedIfSafe, .uncached])
            guard data.count == expectedSize, data.count <= maximumReceiptBytes else {
                throw ResearchVaultReceiptBatchReaderError.entryTooLarge(name)
            }
            guard let receipt = try? decoder.decode(ResearchReceipt.self, from: data),
                  (try? ResearchReceiptValidator.validate(receipt)) != nil else {
                throw ResearchVaultReceiptBatchReaderError.invalidReceipt(name)
            }
            guard seen.insert(receipt.receiptID).inserted else {
                throw ResearchVaultReceiptBatchReaderError.duplicateReceiptID(receipt.receiptID)
            }
            return receipt
        }
        guard !receipts.isEmpty else { return [] }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let request = ResearchVaultReceiptImportRequest(receipts: receipts)
        guard try encoder.encode(request).count <= maximumRequestBytes else {
            throw ResearchVaultReceiptBatchReaderError.requestTooLarge
        }
        return receipts
    }
}
