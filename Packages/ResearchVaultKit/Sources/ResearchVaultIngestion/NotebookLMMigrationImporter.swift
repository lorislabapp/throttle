import CryptoKit
import Foundation
import ResearchVaultModel

public enum NotebookLMMigrationError: Error, Equatable, Sendable {
    case folderUnavailable
    case invalidProjectKey
    case tooManyDocuments
    case unsafeEntry(String)
    case documentTooLarge(String)
    case unsupportedOrUnreadable(String)
    case emptyExport
    case invalidProvenance(String)
}

public enum ResearchReceiptDeterministicIdentity {
    public static func uuid(for value: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return String(
            format: "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )
    }
}

/// Converts a user-created NotebookLM/Takeout export into sealed, idempotent
/// Research Vault receipts without login, browser automation, upload or source
/// mutation. Imported text remains OPEN evidence.
public struct NotebookLMMigrationImporter: Sendable {
    public static let supportedExtensions = ResearchDocumentTextExtractor.supportedExtensions
    public static let maximumDocuments = 256
    public static let maximumDocumentBytes = 512 * 1_024
    public static let maximumExtractedCharacters = 480_000
    public static let findingCharacters = 30_000

    public let root: URL
    public let projectKey: String
    public let sensitivity: ResearchSensitivity

    public init(
        root: URL,
        projectKey: String,
        sensitivity: ResearchSensitivity = .confidential
    ) throws {
        guard projectKey.range(
            of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#,
            options: .regularExpression
        ) != nil else {
            throw NotebookLMMigrationError.invalidProjectKey
        }
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.projectKey = projectKey
        self.sensitivity = sensitivity
    }

    public func load() throws -> NotebookLMMigrationBatch {
        let manager = FileManager.default
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw NotebookLMMigrationError.folderUnavailable
        }
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw NotebookLMMigrationError.folderUnavailable
        }

        let documents = try loadDocuments(from: enumerator)
        let files = documents.map { document in
            NotebookLMMigrationFile(
                relativePath: document.relative,
                byteCount: document.bytes.count,
                extractedCharacterCount: document.text.count,
                sha256: Self.sha256(document.bytes),
                format: document.url.pathExtension.lowercased(),
                notebookURL: document.provenance?.notebookURL,
                sourceIndex: document.provenance?.sourceIndex,
                sourceTitle: document.provenance?.title
            )
        }
        let aggregate = Self.aggregateHash(files)
        let receipts = try zip(documents, files).map { document, file in
            try receipt(document: document, file: file, aggregate: aggregate)
        }
        return NotebookLMMigrationBatch(
            receipts: receipts,
            manifest: NotebookLMMigrationManifest(
                createdAt: Date(),
                projectKey: projectKey,
                sourceFolderName: root.lastPathComponent,
                files: files,
                aggregateSHA256: aggregate
            )
        )
    }

    // The complete directory walk stays in one auditable fail-closed scope.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func loadDocuments(
        from enumerator: FileManager.DirectoryEnumerator
    ) throws -> [MigrationDocument] {
        var documents: [MigrationDocument] = []
        var sourceIndices = Set<Int>()
        for case let candidate as URL in enumerator {
            guard !candidate.lastPathComponent.hasSuffix(".provenance.json") else { continue }
            guard Self.supportedExtensions.contains(candidate.pathExtension.lowercased()) else {
                continue
            }
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            let relative = Self.relativePath(of: candidate, under: root)
            guard Self.isContained(resolved, by: root), let relative else {
                throw NotebookLMMigrationError.unsafeEntry(candidate.lastPathComponent)
            }
            let values = try candidate.resourceValues(
                forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                    .contentModificationDateKey
                ]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw NotebookLMMigrationError.unsafeEntry(relative)
            }
            guard let size = values.fileSize, size <= Self.maximumDocumentBytes else {
                throw NotebookLMMigrationError.documentTooLarge(relative)
            }
            let bytes = try Data(contentsOf: candidate, options: [.mappedIfSafe, .uncached])
            guard bytes.count == size else {
                throw NotebookLMMigrationError.unsafeEntry(relative)
            }
            let text: String
            do {
                text = try ResearchDocumentTextExtractor.extractText(
                    from: candidate,
                    bytes: bytes
                ).trimmingCharacters(in: .whitespacesAndNewlines)
            } catch ResearchDocumentTextExtractorError.ocrUnavailable(let file, let page) {
                throw ResearchDocumentTextExtractorError.ocrUnavailable(file, page: page)
            } catch {
                throw NotebookLMMigrationError.unsupportedOrUnreadable(relative)
            }
            guard !text.isEmpty, text.count <= Self.maximumExtractedCharacters else {
                throw NotebookLMMigrationError.unsupportedOrUnreadable(relative)
            }
            let payloadHash = Self.sha256(bytes)
            let provenance = try Self.loadProvenance(for: candidate, payloadHash: payloadHash)
            if let sourceIndex = provenance?.sourceIndex,
               !sourceIndices.insert(sourceIndex).inserted {
                throw NotebookLMMigrationError.invalidProvenance(relative)
            }
            documents.append(MigrationDocument(
                url: candidate,
                relative: relative,
                bytes: bytes,
                text: text,
                modifiedAt: values.contentModificationDate ?? Date(),
                provenance: provenance
            ))
            guard documents.count <= Self.maximumDocuments else {
                throw NotebookLMMigrationError.tooManyDocuments
            }
        }
        documents.sort { $0.relative.localizedStandardCompare($1.relative) == .orderedAscending }
        guard !documents.isEmpty else { throw NotebookLMMigrationError.emptyExport }

        return documents
    }

    private func receipt(
        document: MigrationDocument,
        file: NotebookLMMigrationFile,
        aggregate: String
    ) throws -> ResearchReceipt {
        let sourceID = "notebooklm-source"
        let displayName: String
        let locator: String
        if let provenance = document.provenance {
            displayName = "\(provenance.title) [source \(provenance.sourceIndex)]"
            locator = "\(provenance.notebookURL)#source-index=\(provenance.sourceIndex)"
        } else {
            displayName = file.relativePath
            locator = "notebooklm-export/\(file.relativePath)"
        }
        return try ResearchReceipt.seal(
            receiptID: ResearchReceiptDeterministicIdentity.uuid(
                for: "\(projectKey)\n\(file.relativePath)\n\(file.sha256)"
            ),
            sessionID: "notebooklm-migration:\(aggregate)",
            agentID: "throttle-notebooklm-migration-v1",
            projectKey: projectKey,
            question: "Imported NotebookLM source: \(displayName)",
            findings: Self.chunks(document.text, maximum: Self.findingCharacters).map {
                ResearchFinding(claim: $0, status: .open, evidenceIDs: [sourceID])
            },
            sources: [
                ResearchSource(
                    id: sourceID,
                    kind: .file,
                    locator: locator,
                    observedAt: document.provenance?.exportedAt ?? document.modifiedAt,
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

    private static func relativePath(of url: URL, under root: URL) -> String? {
        let path = url.standardizedFileURL.path
        let prefix = root.standardizedFileURL.path + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return nil
        }
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

    private static func loadProvenance(
        for payload: URL,
        payloadHash: String
    ) throws -> NotebookLMSourceProvenance? {
        let sidecar = URL(fileURLWithPath: payload.path + ".provenance.json")
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return nil }
        let bytes = try Data(contentsOf: sidecar, options: [.mappedIfSafe, .uncached])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(NotebookLMSourceProvenance.self, from: bytes),
              value.schemaVersion == NotebookLMSourceProvenance.schemaVersion,
              value.sourceIndex >= 0,
              !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.payloadSHA256 == payloadHash,
              let url = URL(string: value.notebookURL),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "notebook.google.com" else {
            throw NotebookLMMigrationError.invalidProvenance(payload.lastPathComponent)
        }
        return value
    }
}

private struct MigrationDocument {
    let url: URL
    let relative: String
    let bytes: Data
    let text: String
    let modifiedAt: Date
    let provenance: NotebookLMSourceProvenance?
}
