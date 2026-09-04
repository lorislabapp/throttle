import Foundation
import ResearchVaultIPCModel
import ResearchVaultModel
import ResearchVaultXPCClient

enum ResearchVaultInboxError: Error, Equatable {
    case bookmarkUnavailable
    case staleBookmark
    case tooManyReceipts
    case invalidReceipt(String)
    case requestTooLarge
}

/// Persists only a macOS security-scoped bookmark. Folder enumeration and file
/// reads happen in Throttle; the helper receives validated sealed DTOs, never a
/// path or bookmark capability.
enum ResearchVaultInboxBookmarkStore {
    private static let bookmarkKey = "researchVaultInboxSecurityScopedBookmark"
    private static let maximumScannedReceipts =
        ResearchVaultIPCContract.maximumReceiptsPerRequest

    static var configuredFolderName: String? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey),
              let resolved = try? resolve(bookmark) else {
            return nil
        }
        return resolved.lastPathComponent
    }

    static func save(folder: URL) throws {
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ResearchVaultInboxError.bookmarkUnavailable
        }
        let bookmark = try folder.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.isDirectoryKey],
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
    }

    static func loadReceipts() throws -> [ResearchReceipt] {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            throw ResearchVaultInboxError.bookmarkUnavailable
        }
        var stale = false
        let folder = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale else { throw ResearchVaultInboxError.staleBookmark }
        guard folder.startAccessingSecurityScopedResource() else {
            throw ResearchVaultInboxError.bookmarkUnavailable
        }
        defer { folder.stopAccessingSecurityScopedResource() }

        do {
            return try ResearchVaultReceiptBatchReader(
                maximumReceiptCount: maximumScannedReceipts
            ).load(from: folder)
        } catch ResearchVaultReceiptBatchReaderError.tooManyReceipts {
            throw ResearchVaultInboxError.tooManyReceipts
        } catch ResearchVaultReceiptBatchReaderError.requestTooLarge {
            throw ResearchVaultInboxError.requestTooLarge
        } catch ResearchVaultReceiptBatchReaderError.entryNotRegularFile(let name) {
            throw ResearchVaultInboxError.invalidReceipt(name)
        } catch ResearchVaultReceiptBatchReaderError.entryTooLarge(let name) {
            throw ResearchVaultInboxError.invalidReceipt(name)
        } catch ResearchVaultReceiptBatchReaderError.invalidReceipt(let name) {
            throw ResearchVaultInboxError.invalidReceipt(name)
        } catch ResearchVaultReceiptBatchReaderError.duplicateReceiptID(let receiptID) {
            throw ResearchVaultInboxError.invalidReceipt(receiptID)
        }
    }

    private static func resolve(_ bookmark: Data) throws -> URL {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale else { throw ResearchVaultInboxError.staleBookmark }
        return url
    }
}
