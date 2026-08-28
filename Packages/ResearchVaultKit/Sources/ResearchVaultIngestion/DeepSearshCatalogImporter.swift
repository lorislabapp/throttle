import CryptoKit
import Foundation
import ResearchVaultModel

public struct ResearchDocumentCandidate: Equatable, Sendable {
    public let documentID: String
    public let title: String
    public let projectKey: String
    public let category: String
    public let libraryPath: String
    public let origins: [String]
    public let content: String
    public let plaintextSHA256: String
    public let byteCount: Int
    public let modifiedAt: Date
    public let sensitivity: ResearchSensitivity

    public init(
        documentID: String,
        title: String,
        projectKey: String,
        category: String,
        libraryPath: String,
        origins: [String],
        content: String,
        plaintextSHA256: String,
        byteCount: Int,
        modifiedAt: Date,
        sensitivity: ResearchSensitivity
    ) {
        self.documentID = documentID
        self.title = title
        self.projectKey = projectKey
        self.category = category
        self.libraryPath = libraryPath
        self.origins = origins
        self.content = content
        self.plaintextSHA256 = plaintextSHA256
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.sensitivity = sensitivity
    }
}

public struct DeepSearshImportEvidence: Equatable, Sendable {
    public let catalogSHA256: String
    public let scannedEntries: Int
    public let acceptedDocuments: Int
    public let acceptedBytes: Int
}

public struct DeepSearshImportBatch: Equatable, Sendable {
    public let documents: [ResearchDocumentCandidate]
    public let evidence: DeepSearshImportEvidence
}

public enum DeepSearshImportError: Error, Equatable, Sendable {
    case rootUnavailable
    case catalogOutsideRoot
    case catalogNotRegularFile
    case catalogTooLarge
    case malformedCatalogLine(Int)
    case duplicateDocumentID(String)
    case invalidDocumentID(String)
    case invalidProjectKey(String)
    case invalidLibraryPath(String)
    case documentOutsideLibrary(String)
    case documentNotRegularFile(String)
    case documentTooLarge(String)
    case sizeMismatch(String)
    case hashMismatch(String)
    case invalidUTF8(String)
    case unsafeDefaultSensitivity
}

/// Read-only, fail-closed adapter for a DeepSearsh catalog snapshot.
///
/// Catalog paths are untrusted input. Every accepted document is confined to
/// `<root>/library`, must be a non-symlink regular file, and is re-hashed from
/// bytes before being returned. The importer never mutates DeepSearsh.
public struct DeepSearshCatalogImporter: Sendable {
    public static let defaultMaximumCatalogBytes = 64 * 1_024 * 1_024
    public static let defaultMaximumDocumentBytes = 8 * 1_024 * 1_024

    private let root: URL
    private let maximumCatalogBytes: Int
    private let maximumDocumentBytes: Int
    private let defaultSensitivity: ResearchSensitivity

    public init(
        root: URL,
        maximumCatalogBytes: Int = Self.defaultMaximumCatalogBytes,
        maximumDocumentBytes: Int = Self.defaultMaximumDocumentBytes,
        defaultSensitivity: ResearchSensitivity = .internal
    ) throws {
        guard defaultSensitivity != .public else {
            throw DeepSearshImportError.unsafeDefaultSensitivity
        }
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.maximumCatalogBytes = maximumCatalogBytes
        self.maximumDocumentBytes = maximumDocumentBytes
        self.defaultSensitivity = defaultSensitivity
    }

    public func load(projectKeys: Set<String>? = nil) throws -> DeepSearshImportBatch {
        let manager = FileManager.default
        var rootIsDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &rootIsDirectory), rootIsDirectory.boolValue else {
            throw DeepSearshImportError.rootUnavailable
        }

        let catalog = root.appendingPathComponent("catalog.jsonl", isDirectory: false)
        guard Self.isContained(catalog, by: root) else {
            throw DeepSearshImportError.catalogOutsideRoot
        }
        let catalogValues = try resourceValues(for: catalog)
        guard catalogValues.isRegularFile == true, catalogValues.isSymbolicLink != true else {
            throw DeepSearshImportError.catalogNotRegularFile
        }
        guard let catalogSize = catalogValues.fileSize, catalogSize <= maximumCatalogBytes else {
            throw DeepSearshImportError.catalogTooLarge
        }
        let catalogData = try Data(contentsOf: catalog, options: [.mappedIfSafe, .uncached])
        guard catalogData.count <= maximumCatalogBytes else {
            throw DeepSearshImportError.catalogTooLarge
        }
        guard let catalogText = String(data: catalogData, encoding: .utf8) else {
            throw DeepSearshImportError.malformedCatalogLine(1)
        }

        let decoder = JSONDecoder()
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var seen = Set<String>()
        var documents: [ResearchDocumentCandidate] = []
        var scanned = 0
        var acceptedBytes = 0

        for (offset, rawLine) in catalogText.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if rawLine.isEmpty { continue }
            scanned += 1
            let lineNumber = offset + 1
            guard let lineData = rawLine.data(using: .utf8),
                  let entry = try? decoder.decode(CatalogEntry.self, from: lineData) else {
                throw DeepSearshImportError.malformedCatalogLine(lineNumber)
            }
            try Self.validateIdentifier(entry.id, error: .invalidDocumentID(entry.id))
            try Self.validateIdentifier(entry.projectSlug, error: .invalidProjectKey(entry.projectSlug))
            guard seen.insert(entry.id).inserted else {
                throw DeepSearshImportError.duplicateDocumentID(entry.id)
            }
            let scopedProject: String
            if let projectKeys {
                let candidates = Set([entry.projectSlug] + entry.projectRefs.map(\.slug))
                    .intersection(projectKeys)
                    .sorted()
                guard let selected = candidates.first else { continue }
                scopedProject = selected
            } else {
                scopedProject = entry.projectSlug
            }
            let referenceSlugs = Dictionary(
                uniqueKeysWithValues: entry.projectRefs.map { ($0.name, $0.slug) }
            )
            let scopedOrigins = (entry.originRecords ?? []).compactMap { record -> String? in
                let recordSlug = referenceSlugs[record.project]
                    ?? (record.project == entry.project ? entry.projectSlug : nil)
                return recordSlug == scopedProject ? record.path : nil
            }

            let relative = try Self.validatedRelativeLibraryPath(entry.libraryPath)
            let document = root.appendingPathComponent(relative, isDirectory: false)
            let resolved = document.resolvingSymlinksInPath()
            let libraryRoot = root.appendingPathComponent("library", isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard Self.isContained(resolved, by: libraryRoot) else {
                throw DeepSearshImportError.documentOutsideLibrary(entry.id)
            }
            let values = try resourceValues(for: document)
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw DeepSearshImportError.documentNotRegularFile(entry.id)
            }
            guard let fileSize = values.fileSize,
                  fileSize >= 0,
                  fileSize <= maximumDocumentBytes else {
                throw DeepSearshImportError.documentTooLarge(entry.id)
            }
            guard fileSize == entry.sizeBytes else {
                throw DeepSearshImportError.sizeMismatch(entry.id)
            }
            let bytes = try Data(contentsOf: document, options: [.mappedIfSafe, .uncached])
            guard bytes.count == fileSize, bytes.count <= maximumDocumentBytes else {
                throw DeepSearshImportError.sizeMismatch(entry.id)
            }
            let hash = Self.sha256(bytes)
            guard hash == entry.sha256.lowercased() else {
                throw DeepSearshImportError.hashMismatch(entry.id)
            }
            guard let content = String(data: bytes, encoding: .utf8) else {
                throw DeepSearshImportError.invalidUTF8(entry.id)
            }
            guard let modifiedAt = dateFormatter.date(from: entry.modifiedUTC)
                    ?? ISO8601DateFormatter().date(from: entry.modifiedUTC) else {
                throw DeepSearshImportError.malformedCatalogLine(lineNumber)
            }
            acceptedBytes += bytes.count
            documents.append(ResearchDocumentCandidate(
                documentID: entry.id,
                title: entry.title,
                projectKey: scopedProject,
                category: entry.category,
                libraryPath: entry.libraryPath,
                origins: scopedOrigins,
                content: content,
                plaintextSHA256: hash,
                byteCount: bytes.count,
                modifiedAt: modifiedAt,
                sensitivity: defaultSensitivity
            ))
        }

        return DeepSearshImportBatch(
            documents: documents,
            evidence: DeepSearshImportEvidence(
                catalogSHA256: Self.sha256(catalogData),
                scannedEntries: scanned,
                acceptedDocuments: documents.count,
                acceptedBytes: acceptedBytes
            )
        )
    }

    private func resourceValues(for url: URL) throws -> URLResourceValues {
        try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    }

    private static func validatedRelativeLibraryPath(_ path: String) throws -> String {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else {
            throw DeepSearshImportError.invalidLibraryPath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first == "library",
              components.count > 1,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw DeepSearshImportError.invalidLibraryPath(path)
        }
        return path
    }

    private static func validateIdentifier(_ value: String, error: DeepSearshImportError) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !value.isEmpty, value.count <= 160,
              value.unicodeScalars.allSatisfy(allowed.contains) else { throw error }
    }

    private static func isContained(_ candidate: URL, by directory: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return candidatePath == directoryPath || candidatePath.hasPrefix(directoryPath + "/")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct CatalogEntry: Decodable {
    let id: String
    let title: String
    let projectSlug: String
    let category: String
    let libraryPath: String
    let sha256: String
    let sizeBytes: Int
    let modifiedUTC: String
    let origins: [String]
    let projectRefs: [ProjectReference]
    let project: String
    let originRecords: [OriginRecord]?

    enum CodingKeys: String, CodingKey {
        case id, title, category, sha256, origins
        case projectSlug = "project_slug"
        case libraryPath = "library_path"
        case sizeBytes = "size_bytes"
        case modifiedUTC = "modified_utc"
        case projectRefs = "project_refs"
        case project
        case originRecords = "origin_records"
    }
}

private struct ProjectReference: Decodable {
    let name: String
    let slug: String
}

private struct OriginRecord: Decodable {
    let path: String
    let project: String
}
