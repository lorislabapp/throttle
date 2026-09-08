import CryptoKit
import Foundation
import ResearchVaultModel

public enum ManualResearchFileImportError: Error, Equatable, Sendable {
    case invalidProjectKey
    case emptySelection
    case tooManyDocuments
    case unsafeEntry(String)
    case unsupportedExtension(String)
    case documentTooLarge(String)
    case unsupportedOrUnreadable(String)
}

public struct ManualResearchImportFile: Equatable, Sendable {
    public let name: String
    public let byteCount: Int
    public let extractedCharacterCount: Int
    public let sha256: String
    public let format: String

    public init(
        name: String,
        byteCount: Int,
        extractedCharacterCount: Int,
        sha256: String,
        format: String
    ) {
        self.name = name
        self.byteCount = byteCount
        self.extractedCharacterCount = extractedCharacterCount
        self.sha256 = sha256
        self.format = format
    }
}

public struct ManualResearchImportBatch: Sendable {
    public let receipts: [ResearchReceipt]
    public let files: [ManualResearchImportFile]
    public let aggregateSHA256: String

    public init(
        receipts: [ResearchReceipt],
        files: [ManualResearchImportFile],
        aggregateSHA256: String
    ) {
        self.receipts = receipts
        self.files = files
        self.aggregateSHA256 = aggregateSHA256
    }
}

/// Converts files explicitly selected by the user into sealed, idempotent
/// Research Vault receipts. It stores a privacy-preserving display locator,
/// never the absolute source path, and keeps every imported finding OPEN.
public struct ManualResearchFileImporter: Sendable {
    public static let supportedExtensions = ResearchDocumentTextExtractor.supportedExtensions
    public static let maximumDocuments = 32
    public static let maximumDocumentBytes = 512 * 1_024
    public static let maximumExtractedCharacters = 480_000
    public static let findingCharacters = 30_000

    public let files: [URL]
    public let projectKey: String
    public let sensitivity: ResearchSensitivity

    public init(
        files: [URL],
        projectKey: String,
        sensitivity: ResearchSensitivity = .confidential
    ) throws {
        guard projectKey.range(
            of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#,
            options: .regularExpression
        ) != nil else {
            throw ManualResearchFileImportError.invalidProjectKey
        }
        self.files = files
        self.projectKey = projectKey
        self.sensitivity = sensitivity
    }

    // The complete user-selected batch is validated in one fail-closed scope.
    // swiftlint:disable:next function_body_length
    public func load() throws -> ManualResearchImportBatch {
        guard !files.isEmpty else { throw ManualResearchFileImportError.emptySelection }
        guard files.count <= Self.maximumDocuments else {
            throw ManualResearchFileImportError.tooManyDocuments
        }

        var seenPaths = Set<String>()
        let documents = try files.map { candidate -> ManualDocument in
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            let name = candidate.lastPathComponent
            guard seenPaths.insert(resolved.path).inserted else {
                throw ManualResearchFileImportError.unsafeEntry(name)
            }
            let fileExtension = candidate.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(fileExtension) else {
                throw ManualResearchFileImportError.unsupportedExtension(name)
            }
            let values = try candidate.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                .contentModificationDateKey
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ManualResearchFileImportError.unsafeEntry(name)
            }
            guard let size = values.fileSize, size <= Self.maximumDocumentBytes else {
                throw ManualResearchFileImportError.documentTooLarge(name)
            }
            let bytes = try Data(contentsOf: candidate, options: [.mappedIfSafe, .uncached])
            guard bytes.count == size else {
                throw ManualResearchFileImportError.unsafeEntry(name)
            }
            let text = try Self.extractedText(from: candidate, bytes: bytes)
            return ManualDocument(
                name: name,
                bytes: bytes,
                text: text,
                modifiedAt: values.contentModificationDate ?? Date(),
                format: fileExtension
            )
        }.sorted {
            if $0.name != $1.name {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return Self.sha256($0.bytes) < Self.sha256($1.bytes)
        }

        let importedFiles = documents.map { document in
            ManualResearchImportFile(
                name: document.name,
                byteCount: document.bytes.count,
                extractedCharacterCount: document.text.count,
                sha256: Self.sha256(document.bytes),
                format: document.format
            )
        }
        let aggregate = Self.aggregateHash(importedFiles)
        let receipts = try zip(documents, importedFiles).map { document, file in
            try receipt(document: document, file: file, aggregate: aggregate)
        }
        return ManualResearchImportBatch(
            receipts: receipts,
            files: importedFiles,
            aggregateSHA256: aggregate
        )
    }

    private static func extractedText(from url: URL, bytes: Data) throws -> String {
        let text: String
        do {
            text = try ResearchDocumentTextExtractor.extractText(from: url, bytes: bytes)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch ResearchDocumentTextExtractorError.ocrUnavailable(let file, let page) {
            throw ResearchDocumentTextExtractorError.ocrUnavailable(file, page: page)
        } catch {
            throw ManualResearchFileImportError.unsupportedOrUnreadable(url.lastPathComponent)
        }
        guard !text.isEmpty, text.count <= maximumExtractedCharacters else {
            throw ManualResearchFileImportError.unsupportedOrUnreadable(url.lastPathComponent)
        }
        return text
    }

    private func receipt(
        document: ManualDocument,
        file: ManualResearchImportFile,
        aggregate: String
    ) throws -> ResearchReceipt {
        let sourceID = "manual-file"
        return try ResearchReceipt.seal(
            receiptID: ResearchReceiptDeterministicIdentity.uuid(
                for: "\(projectKey)\n\(file.name)\n\(file.sha256)"
            ),
            sessionID: "manual-file-import:\(aggregate)",
            agentID: "throttle-manual-file-import-v1",
            projectKey: projectKey,
            question: "Imported research file: \(file.name)",
            findings: Self.chunks(document.text, maximum: Self.findingCharacters).map {
                ResearchFinding(claim: $0, status: .open, evidenceIDs: [sourceID])
            },
            sources: [
                ResearchSource(
                    id: sourceID,
                    kind: .file,
                    locator: "manual-import/\(file.name)",
                    observedAt: document.modifiedAt,
                    sha256: file.sha256
                )
            ],
            openQuestions: ["Imported source content has not been independently verified."],
            sensitivity: sensitivity,
            createdAt: document.modifiedAt
        )
    }

    private static func chunks(_ text: String, maximum: Int) -> [String] {
        var result: [String] = []
        var remainder = text[...]
        while !remainder.isEmpty {
            let end = remainder.index(
                remainder.startIndex,
                offsetBy: min(maximum, remainder.count)
            )
            var boundary = end
            if end < remainder.endIndex,
               let whitespace = remainder[..<end].lastIndex(where: { $0.isWhitespace }),
               remainder.distance(from: whitespace, to: end) < 2_000 {
                boundary = whitespace
            }
            let chunk = remainder[..<boundary]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { result.append(chunk) }
            remainder = remainder[boundary...].drop(while: { $0.isWhitespace })
        }
        return result
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func aggregateHash(_ files: [ManualResearchImportFile]) -> String {
        let canonical = files.map {
            "\($0.name)\u{0}\($0.byteCount)\u{0}\($0.sha256)"
        }.joined(separator: "\n")
        return sha256(Data(canonical.utf8))
    }
}

private struct ManualDocument {
    let name: String
    let bytes: Data
    let text: String
    let modifiedAt: Date
    let format: String
}
