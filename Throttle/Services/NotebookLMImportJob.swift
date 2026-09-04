import CryptoKit
import Foundation
import ResearchVaultIngestion

struct NotebookLMNotebookDescriptor: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let url: URL
    let sourceCount: Int
}

struct NotebookLMSourceDescriptor: Codable, Equatable, Sendable, Identifiable {
    let index: Int
    let title: String
    let sourceID: String?

    var id: Int { index }
}

struct NotebookLMSourceExport: Equatable, Sendable {
    let markdown: Data
    let title: String?

    init(markdown: Data, title: String? = nil) {
        self.markdown = markdown
        self.title = title
    }
}

protocol NotebookLMGatewayServing: Sendable {
    func listNotebooks() async throws -> [NotebookLMNotebookDescriptor]
    func listSources(notebookURL: URL) async throws -> [NotebookLMSourceDescriptor]
    func exportSource(notebookURL: URL, index: Int) async throws -> NotebookLMSourceExport
}

enum NotebookLMImportJobError: Error, Equatable {
    case invalidNotebook
    case invalidInventory
    case stagingUnavailable
    case checkpointMismatch
    case conflictingExport(Int)
    case exportTooLarge(Int)
    case exportIdentityMismatch(Int)
}

enum NotebookLMImportPhase: Equatable, Sendable {
    case idle, listing, exporting, paused, complete
}

actor NotebookLMImportJob {
    struct Progress: Equatable, Sendable {
        let phase: NotebookLMImportPhase
        let completed: Int
        let total: Int
        let currentTitle: String?

        static let idle = Progress(phase: .idle, completed: 0, total: 0, currentTitle: nil)
    }

    private struct CheckpointEntry: Codable {
        let index: Int
        let title: String
        let filename: String
        let sha256: String
    }

    private struct Checkpoint: Codable {
        static let schemaVersion = 2
        let schemaVersion: Int
        let notebookURL: String
        var completed: [CheckpointEntry]
    }

    private let gateway: any NotebookLMGatewayServing
    private let now: @Sendable () -> Date
    private var pauseRequested = false
    private(set) var progress = Progress.idle

    init(
        gateway: any NotebookLMGatewayServing,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.gateway = gateway
        self.now = now
    }

    @discardableResult
    func run(
        notebook: NotebookLMNotebookDescriptor,
        stagingFolder: URL,
        maximumNewExports: Int? = nil
    ) async throws -> Progress {
        pauseRequested = false
        guard notebook.url.scheme == "https",
              notebook.url.host?.lowercased() == "notebook.google.com" else {
            throw NotebookLMImportJobError.invalidNotebook
        }
        try prepare(folder: stagingFolder)
        progress = Progress(phase: .listing, completed: 0, total: 0, currentTitle: nil)
        let sources = try await gateway.listSources(notebookURL: notebook.url)
            .sorted { $0.index < $1.index }
        try validate(sources: sources)

        let checkpointURL = stagingFolder.appendingPathComponent(".notebooklm-import-checkpoint.json")
        var (checkpoint, completed) = try validatedCheckpoint(
            at: checkpointURL,
            notebookURL: notebook.url,
            folder: stagingFolder,
            sources: sources
        )
        var newExports = 0

        for source in sources where completed[source.index] == nil {
            if pauseRequested || maximumNewExports.map({ newExports >= $0 }) == true {
                progress = Progress(
                    phase: .paused,
                    completed: completed.count,
                    total: sources.count,
                    currentTitle: nil
                )
                return progress
            }
            try Task.checkCancellation()
            progress = Progress(
                phase: .exporting,
                completed: completed.count,
                total: sources.count,
                currentTitle: source.title
            )
            let entry = try await exportAndStage(
                source: source,
                inventory: sources,
                completedTitles: completed.values.map(\.title),
                notebookURL: notebook.url,
                folder: stagingFolder
            )
            completed[source.index] = entry
            checkpoint.completed = completed.values.sorted { $0.index < $1.index }
            try persist(checkpoint, at: checkpointURL)
            newExports += 1
        }

        return try completedProgress(completed: completed, sources: sources)
    }

    func requestPause() {
        pauseRequested = true
    }
}

private extension NotebookLMImportJob {
    private func validate(sources: [NotebookLMSourceDescriptor]) throws {
        guard !sources.isEmpty,
              sources.count <= NotebookLMMigrationImporter.maximumDocuments,
              Set(sources.map(\.index)).count == sources.count,
              sources.map(\.index).sorted() == Array(0 ..< sources.count) else {
            throw NotebookLMImportJobError.invalidInventory
        }
    }

    private func validatedCheckpoint(
        at checkpointURL: URL,
        notebookURL: URL,
        folder: URL,
        sources: [NotebookLMSourceDescriptor]
    ) throws -> (Checkpoint, [Int: CheckpointEntry]) {
        let checkpoint = try loadCheckpoint(at: checkpointURL, notebookURL: notebookURL)
        let completed = Dictionary(uniqueKeysWithValues: checkpoint.completed.map { ($0.index, $0) })
        try validateCompleted(completed, in: folder)
        try validateExportIdentities(
            completed.values.map(\.title),
            expected: sources.map(\.title),
            requireComplete: false
        )
        return (checkpoint, completed)
    }

    private func completedProgress(
        completed: [Int: CheckpointEntry],
        sources: [NotebookLMSourceDescriptor]
    ) throws -> Progress {
        try validateExportIdentities(
            completed.values.map(\.title),
            expected: sources.map(\.title),
            requireComplete: true
        )
        let result = Progress(
            phase: .complete,
            completed: completed.count,
            total: sources.count,
            currentTitle: nil
        )
        progress = result
        return result
    }

    private func exportAndStage(
        source: NotebookLMSourceDescriptor,
        inventory: [NotebookLMSourceDescriptor],
        completedTitles: [String],
        notebookURL: URL,
        folder: URL
    ) async throws -> CheckpointEntry {
        let exported = try await gateway.exportSource(
            notebookURL: notebookURL,
            index: source.index
        )
        guard exported.markdown.count <= NotebookLMMigrationImporter.maximumDocumentBytes else {
            throw NotebookLMImportJobError.exportTooLarge(source.index)
        }
        let authoritativeSource: NotebookLMSourceDescriptor
        if let exportedTitle = exported.title {
            let canonical = Self.canonicalSourceTitle(exportedTitle)
            let matching = inventory.filter { Self.canonicalSourceTitle($0.title) == canonical }
            let used = completedTitles.filter { Self.canonicalSourceTitle($0) == canonical }.count
            guard matching.indices.contains(used) else {
                throw NotebookLMImportJobError.exportIdentityMismatch(source.index)
            }
            let identity = matching[used]
            authoritativeSource = NotebookLMSourceDescriptor(
                index: source.index,
                title: identity.title,
                sourceID: identity.sourceID
            )
        } else {
            authoritativeSource = source
        }
        return try stage(
            exported.markdown,
            source: authoritativeSource,
            notebookURL: notebookURL,
            folder: folder
        )
    }

    private func prepare(folder: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: folder.path) {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw NotebookLMImportJobError.stagingUnavailable
        }
    }

    private func loadCheckpoint(at url: URL, notebookURL: URL) throws -> Checkpoint {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Checkpoint(
                schemaVersion: Checkpoint.schemaVersion,
                notebookURL: notebookURL.absoluteString,
                completed: []
            )
        }
        let checkpoint = try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: url))
        guard checkpoint.schemaVersion == Checkpoint.schemaVersion,
              checkpoint.notebookURL == notebookURL.absoluteString,
              Set(checkpoint.completed.map(\.index)).count == checkpoint.completed.count else {
            throw NotebookLMImportJobError.checkpointMismatch
        }
        return checkpoint
    }

    private func validateCompleted(_ entries: [Int: CheckpointEntry], in folder: URL) throws {
        for entry in entries.values {
            let payload = folder.appendingPathComponent(entry.filename)
            let sidecar = URL(fileURLWithPath: payload.path + ".provenance.json")
            guard let bytes = try? Data(contentsOf: payload),
                  Self.sha256(bytes) == entry.sha256,
                  FileManager.default.fileExists(atPath: sidecar.path) else {
                throw NotebookLMImportJobError.conflictingExport(entry.index)
            }
        }
    }

    private func stage(
        _ bytes: Data,
        source: NotebookLMSourceDescriptor,
        notebookURL: URL,
        folder: URL
    ) throws -> CheckpointEntry {
        let hash = Self.sha256(bytes)
        let filename = String(format: "%04d--%@.md", source.index, Self.slug(source.title))
        let payload = folder.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: payload.path) {
            guard (try? Data(contentsOf: payload)) == bytes else {
                throw NotebookLMImportJobError.conflictingExport(source.index)
            }
        } else {
            try writeWithoutOverwrite(bytes, to: payload)
        }
        let provenance = NotebookLMSourceProvenance(
            notebookURL: notebookURL.absoluteString,
            sourceIndex: source.index,
            title: source.title,
            exportedAt: now(),
            payloadSHA256: hash
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let sidecar = URL(fileURLWithPath: payload.path + ".provenance.json")
        try writeWithoutOverwrite(encoder.encode(provenance), to: sidecar)
        return CheckpointEntry(
            index: source.index,
            title: source.title,
            filename: filename,
            sha256: hash
        )
    }

    private func writeWithoutOverwrite(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            "." + destination.lastPathComponent + ".stage-" + UUID().uuidString
        )
        try data.write(to: temporary, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.linkItem(at: temporary, to: destination)
    }

    private func persist(_ checkpoint: Checkpoint, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(checkpoint).write(to: url, options: [.atomic])
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func slug(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = title.lowercased().unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let compact = String(scalars).split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return String((compact.isEmpty ? "source" : compact).prefix(80))
    }

    private static func canonicalSourceTitle(_ title: String) -> String {
        var canonical = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if canonical.hasSuffix("open_in_new") {
            canonical.removeLast("open_in_new".count)
        }
        return canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validateExportIdentities(
        _ exported: [String],
        expected: [String],
        requireComplete: Bool
    ) throws {
        let expectedCounts = Dictionary(
            grouping: expected.map(Self.canonicalSourceTitle),
            by: { $0 }
        ).mapValues(\.count)
        let exportedCounts = Dictionary(
            grouping: exported.map(Self.canonicalSourceTitle),
            by: { $0 }
        ).mapValues(\.count)
        let isSubset = exportedCounts.allSatisfy { title, count in
            count <= expectedCounts[title, default: 0]
        }
        guard isSubset, !requireComplete || exportedCounts == expectedCounts else {
            throw NotebookLMImportJobError.invalidInventory
        }
    }
}
