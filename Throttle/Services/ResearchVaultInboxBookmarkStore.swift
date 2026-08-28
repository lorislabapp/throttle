import AppKit
import CryptoKit
import Foundation
import PDFKit
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
    private static let maximumScannedReceipts = ResearchVaultIPCContract.maximumReceiptsPerRequest

    static var configuredFolderName: String? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey),
              let resolved = try? resolve(bookmark) else { return nil }
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

enum NotebookLMMigrationError: Error, Equatable {
    case folderUnavailable
    case invalidProjectKey
    case tooManyDocuments
    case unsafeEntry(String)
    case documentTooLarge(String)
    case unsupportedOrUnreadable(String)
    case emptyExport
}

struct NotebookLMMigrationFile: Codable, Equatable {
    let relativePath: String
    let byteCount: Int
    let extractedCharacterCount: Int
    let sha256: String
    let format: String
}

struct NotebookLMMigrationManifest: Codable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let createdAt: Date
    let projectKey: String
    let sourceFolderName: String
    let files: [NotebookLMMigrationFile]
    let aggregateSHA256: String

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

struct NotebookLMMigrationBatch {
    let receipts: [ResearchReceipt]
    let manifest: NotebookLMMigrationManifest
}

/// Converts a user-created NotebookLM/Takeout export into sealed, idempotent
/// Research Vault receipts. It never logs in, drives a browser, uploads data or
/// mutates the selected folder. Imported text remains OPEN evidence: copying a
/// source does not verify its claims.
struct NotebookLMMigrationImporter {
    static let supportedExtensions: Set<String> = [
        "md", "markdown", "txt", "csv", "json", "jsonl", "html", "htm",
        "rtf", "docx", "pdf",
    ]
    static let maximumDocuments = 256
    static let maximumDocumentBytes = 512 * 1_024
    static let maximumExtractedCharacters = 480_000
    static let findingCharacters = 30_000

    let root: URL
    let projectKey: String
    let sensitivity: ResearchSensitivity

    init(root: URL, projectKey: String, sensitivity: ResearchSensitivity = .confidential) throws {
        guard projectKey.range(
            of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#,
            options: .regularExpression
        ) != nil else { throw NotebookLMMigrationError.invalidProjectKey }
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.projectKey = projectKey
        self.sensitivity = sensitivity
    }

    func load() throws -> NotebookLMMigrationBatch {
        let manager = FileManager.default
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw NotebookLMMigrationError.folderUnavailable
        }
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw NotebookLMMigrationError.folderUnavailable }

        var documents: [(url: URL, relative: String, bytes: Data, text: String, modifiedAt: Date)] = []
        for case let candidate as URL in enumerator {
            let ext = candidate.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else { continue }
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            let relative = Self.relativePath(of: candidate, under: root)
            guard Self.isContained(resolved, by: root), let relative else {
                throw NotebookLMMigrationError.unsafeEntry(candidate.lastPathComponent)
            }
            let values = try candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw NotebookLMMigrationError.unsafeEntry(relative)
            }
            guard let size = values.fileSize, size <= Self.maximumDocumentBytes else {
                throw NotebookLMMigrationError.documentTooLarge(relative)
            }
            let bytes = try Data(contentsOf: candidate, options: [.mappedIfSafe, .uncached])
            guard bytes.count == size else { throw NotebookLMMigrationError.unsafeEntry(relative) }
            let text = try Self.extractText(from: candidate, bytes: bytes)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= Self.maximumExtractedCharacters else {
                throw NotebookLMMigrationError.unsupportedOrUnreadable(relative)
            }
            documents.append((candidate, relative, bytes, text, values.contentModificationDate ?? Date()))
            guard documents.count <= Self.maximumDocuments else {
                throw NotebookLMMigrationError.tooManyDocuments
            }
        }
        documents.sort { $0.relative.localizedStandardCompare($1.relative) == .orderedAscending }
        guard !documents.isEmpty else { throw NotebookLMMigrationError.emptyExport }

        let files = documents.map {
            NotebookLMMigrationFile(
                relativePath: $0.relative,
                byteCount: $0.bytes.count,
                extractedCharacterCount: $0.text.count,
                sha256: Self.sha256($0.bytes),
                format: $0.url.pathExtension.lowercased()
            )
        }
        let aggregate = Self.aggregateHash(files)
        let sessionID = "notebooklm-migration:\(aggregate)"
        let receipts = try zip(documents, files).map { document, file in
            let sourceID = "notebooklm-source"
            let source = ResearchSource(
                id: sourceID,
                kind: .file,
                locator: "notebooklm-export/\(file.relativePath)",
                observedAt: document.modifiedAt,
                sha256: file.sha256
            )
            let chunks = Self.chunks(document.text, maximum: Self.findingCharacters)
            return try ResearchReceipt.seal(
                receiptID: Self.deterministicUUID("\(projectKey)\n\(file.relativePath)\n\(file.sha256)"),
                sessionID: sessionID,
                agentID: "throttle-notebooklm-migration-v1",
                projectKey: projectKey,
                question: "Imported NotebookLM source: \(file.relativePath)",
                findings: chunks.map {
                    ResearchFinding(claim: $0, status: .open, evidenceIDs: [sourceID])
                },
                sources: [source],
                openQuestions: ["Imported source content has not been independently verified."],
                sensitivity: sensitivity,
                createdAt: document.modifiedAt
            )
        }
        return NotebookLMMigrationBatch(
            receipts: receipts,
            manifest: NotebookLMMigrationManifest(
                schemaVersion: NotebookLMMigrationManifest.schemaVersion,
                createdAt: Date(),
                projectKey: projectKey,
                sourceFolderName: root.lastPathComponent,
                files: files,
                aggregateSHA256: aggregate
            )
        )
    }

    private static func extractText(from url: URL, bytes: Data) throws -> String {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "txt", "csv", "json", "jsonl":
            guard let text = String(data: bytes, encoding: .utf8) else {
                throw NotebookLMMigrationError.unsupportedOrUnreadable(url.lastPathComponent)
            }
            return text
        case "html", "htm":
            return try attributedText(bytes, type: .html, name: url.lastPathComponent)
        case "rtf":
            return try attributedText(bytes, type: .rtf, name: url.lastPathComponent)
        case "docx":
            return try attributedText(bytes, type: .officeOpenXML, name: url.lastPathComponent)
        case "pdf":
            guard let document = PDFDocument(data: bytes) else {
                throw NotebookLMMigrationError.unsupportedOrUnreadable(url.lastPathComponent)
            }
            let pages = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
            guard !pages.isEmpty else {
                throw NotebookLMMigrationError.unsupportedOrUnreadable(url.lastPathComponent)
            }
            return pages.joined(separator: "\n\n")
        default:
            throw NotebookLMMigrationError.unsupportedOrUnreadable(url.lastPathComponent)
        }
    }

    private static func attributedText(
        _ bytes: Data,
        type: NSAttributedString.DocumentType,
        name: String
    ) throws -> String {
        do {
            return try NSAttributedString(
                data: bytes,
                options: [.documentType: type, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
            ).string
        } catch {
            throw NotebookLMMigrationError.unsupportedOrUnreadable(name)
        }
    }

    private static func chunks(_ text: String, maximum: Int) -> [String] {
        var chunks: [String] = []
        var remainder = text[...]
        while !remainder.isEmpty {
            let end = remainder.index(remainder.startIndex, offsetBy: min(maximum, remainder.count))
            var boundary = end
            if end < remainder.endIndex,
               let whitespace = remainder[..<end].lastIndex(where: { $0.isWhitespace }),
               remainder.distance(from: whitespace, to: end) < 2_000 {
                boundary = whitespace
            }
            let chunk = remainder[..<boundary].trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { chunks.append(chunk) }
            remainder = remainder[boundary...].drop(while: { $0.isWhitespace })
        }
        return chunks
    }

    private static func relativePath(of url: URL, under root: URL) -> String? {
        let path = url.standardizedFileURL.path
        let prefix = root.standardizedFileURL.path + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return relative
    }

    private static func isContained(_ candidate: URL, by directory: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return candidatePath == directoryPath || candidatePath.hasPrefix(directoryPath + "/")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func aggregateHash(_ files: [NotebookLMMigrationFile]) -> String {
        let canonical = files.map {
            "\($0.relativePath)\u{0}\($0.byteCount)\u{0}\($0.sha256)"
        }.joined(separator: "\n")
        return sha256(Data(canonical.utf8))
    }

    private static func deterministicUUID(_ value: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return String(format:
            "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )
    }
}
