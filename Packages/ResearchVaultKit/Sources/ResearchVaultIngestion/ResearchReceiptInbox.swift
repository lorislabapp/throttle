import CryptoKit
import Foundation
import ResearchVaultModel

public struct ResearchReceiptInboxBatch: Sendable {
    public let receipts: [ResearchReceipt]
    public let snapshotSHA256: String
    public let acceptedBytes: Int
}

public enum ResearchReceiptInboxError: Error, Equatable, Sendable {
    case unavailable
    case entryNotRegularFile(String)
    case entryTooLarge(String)
    case invalidReceipt(String)
    case duplicateReceiptID(String)
}

/// Read-only scanner for a Finder-visible agent inbox. Producers use atomic
/// rename to place `*.research-receipt.json`; partially written or invalid
/// files block the batch rather than being silently skipped.
public struct ResearchReceiptInbox: Sendable {
    public static let fileSuffix = ".research-receipt.json"
    public static let defaultMaximumReceiptBytes = 2 * 1_024 * 1_024

    private let root: URL
    private let maximumReceiptBytes: Int

    public init(root: URL, maximumReceiptBytes: Int = Self.defaultMaximumReceiptBytes) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.maximumReceiptBytes = maximumReceiptBytes
    }

    public func scan() throws -> ResearchReceiptInboxBatch {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ResearchReceiptInboxError.unavailable
        }
        let entries = try manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ).filter { $0.lastPathComponent.hasSuffix(Self.fileSuffix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var receipts: [ResearchReceipt] = []
        var seen = Set<String>()
        var snapshot = SHA256()
        var acceptedBytes = 0
        for entry in entries {
            let name = entry.lastPathComponent
            let values = try entry.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ResearchReceiptInboxError.entryNotRegularFile(name)
            }
            guard let fileSize = values.fileSize, fileSize <= maximumReceiptBytes else {
                throw ResearchReceiptInboxError.entryTooLarge(name)
            }
            let data = try Data(contentsOf: entry, options: [.mappedIfSafe, .uncached])
            guard data.count == fileSize, data.count <= maximumReceiptBytes else {
                throw ResearchReceiptInboxError.entryTooLarge(name)
            }
            guard let receipt = try? decoder.decode(ResearchReceipt.self, from: data),
                  (try? ResearchReceiptValidator.validate(receipt)) != nil else {
                throw ResearchReceiptInboxError.invalidReceipt(name)
            }
            guard seen.insert(receipt.receiptID).inserted else {
                throw ResearchReceiptInboxError.duplicateReceiptID(receipt.receiptID)
            }
            snapshot.update(data: Data(name.utf8))
            snapshot.update(data: Data([0]))
            snapshot.update(data: data)
            acceptedBytes += data.count
            receipts.append(receipt)
        }
        return ResearchReceiptInboxBatch(
            receipts: receipts,
            snapshotSHA256: snapshot.finalize().map { String(format: "%02x", $0) }.joined(),
            acceptedBytes: acceptedBytes
        )
    }
}
