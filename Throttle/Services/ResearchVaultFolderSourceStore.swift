import AppKit
import CoreServices
import Foundation
import ResearchVaultIngestion

struct ResearchVaultFolderSource: Codable, Equatable, Identifiable {
    let id: UUID
    let spaceID: String
    let projectKey: String
    let name: String
    let bookmark: Data
    var fingerprints: [String: String]

    init(
        id: UUID = UUID(),
        spaceID: String,
        projectKey: String,
        name: String,
        bookmark: Data,
        fingerprints: [String: String] = [:]
    ) {
        self.id = id
        self.spaceID = spaceID
        self.projectKey = projectKey
        self.name = name
        self.bookmark = bookmark
        self.fingerprints = fingerprints
    }
}

enum ResearchVaultFolderSourceError: Error {
    case unavailable
    case staleBookmark
    case invalidDirectory
    case tooManyFiles
}

enum ResearchVaultFolderSourceStore {
    private static let key = "researchVault.folderSources.v1"
    private static let maximumSources = 32
    private static let maximumFilesPerScan = 256

    static func load(defaults: UserDefaults = .standard) -> [ResearchVaultFolderSource] {
        guard let data = defaults.data(forKey: key),
              let sources = try? JSONDecoder().decode([ResearchVaultFolderSource].self, from: data)
        else { return [] }
        return Array(sources.prefix(maximumSources))
    }

    static func add(
        folder: URL,
        spaceID: String,
        projectKey: String,
        defaults: UserDefaults = .standard
    ) throws -> ResearchVaultFolderSource {
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ResearchVaultFolderSourceError.invalidDirectory
        }
        let bookmark = try folder.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.isDirectoryKey],
            relativeTo: nil
        )
        let source = ResearchVaultFolderSource(
            spaceID: spaceID,
            projectKey: projectKey,
            name: folder.lastPathComponent,
            bookmark: bookmark
        )
        var sources = load(defaults: defaults)
        if let existing = sources.firstIndex(where: {
            $0.spaceID == spaceID && $0.name == source.name && $0.bookmark == bookmark
        }) {
            return sources[existing]
        }
        guard sources.count < maximumSources else {
            throw ResearchVaultFolderSourceError.tooManyFiles
        }
        sources.append(source)
        try save(sources, defaults: defaults)
        return source
    }

    static func remove(id: UUID, defaults: UserDefaults = .standard) throws {
        try save(load(defaults: defaults).filter { $0.id != id }, defaults: defaults)
    }

    static func resolve(_ source: ResearchVaultFolderSource) throws -> URL {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: source.bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale else { throw ResearchVaultFolderSourceError.staleBookmark }
        return url
    }

    static func changedFiles(
        for source: ResearchVaultFolderSource,
        at folder: URL
    ) throws -> (urls: [URL], fingerprints: [String: String]) {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw ResearchVaultFolderSourceError.unavailable }
        var fingerprints: [String: String] = [:]
        var changed: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            guard ManualResearchFileImporter.supportedExtensions.contains(
                url.pathExtension.lowercased()
            ) else { continue }
            let relative = String(url.path.dropFirst(folder.path.count)).trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            let fingerprint = "\(values.fileSize ?? -1):\(values.contentModificationDate?.timeIntervalSince1970 ?? -1)"
            fingerprints[relative] = fingerprint
            if source.fingerprints[relative] != fingerprint { changed.append(url) }
            if fingerprints.count > maximumFilesPerScan {
                throw ResearchVaultFolderSourceError.tooManyFiles
            }
        }
        return (changed.sorted { $0.path < $1.path }, fingerprints)
    }

    static func markSynced(
        id: UUID,
        fingerprints: [String: String],
        defaults: UserDefaults = .standard
    ) throws {
        var sources = load(defaults: defaults)
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].fingerprints = fingerprints
        try save(sources, defaults: defaults)
    }

    private static func save(
        _ sources: [ResearchVaultFolderSource],
        defaults: UserDefaults
    ) throws {
        defaults.set(try JSONEncoder().encode(sources), forKey: key)
    }
}

/// FSEvents is a wake-up signal, never the source of truth. Every event causes
/// a bounded rescan using persisted fingerprints, and the periodic UI task is
/// retained as recovery for dropped/coalesced events.
final class ResearchVaultFolderMonitor: @unchecked Sendable {
    private final class CallbackBox: @unchecked Sendable {
        let handler: @Sendable () -> Void
        init(handler: @escaping @Sendable () -> Void) { self.handler = handler }
    }

    private let callbackBox: CallbackBox
    private let accessedURLs: [URL]
    private var stream: FSEventStreamRef?

    init?(
        sources: [ResearchVaultFolderSource],
        handler: @escaping @Sendable () -> Void
    ) {
        let resolved = sources.compactMap { try? ResearchVaultFolderSourceStore.resolve($0) }
        guard !resolved.isEmpty else { return nil }
        let accessed = resolved.filter { $0.startAccessingSecurityScopedResource() }
        guard !accessed.isEmpty else { return nil }
        accessedURLs = accessed
        callbackBox = CallbackBox(handler: handler)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue().handler()
        }
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            accessed.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
            )
        )
        guard let stream else {
            accessed.forEach { $0.stopAccessingSecurityScopedResource() }
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            accessed.forEach { $0.stopAccessingSecurityScopedResource() }
            return nil
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
    }
}
