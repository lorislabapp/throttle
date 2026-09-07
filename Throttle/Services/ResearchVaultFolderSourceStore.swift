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
    /// Which directory level under this folder names the project a file belongs
    /// to, counting from zero. A whole research library can then be granted once
    /// and still feed every Space, instead of costing one macOS permission per
    /// project — which, at ninety projects across eight categories, was the
    /// difference between a setup someone finishes and one they abandon.
    /// `nil` keeps the folder's own `projectKey` for everything inside it.
    var projectSegment: Int?

    init(
        id: UUID = UUID(),
        spaceID: String,
        projectKey: String,
        name: String,
        bookmark: Data,
        fingerprints: [String: String] = [:],
        projectSegment: Int? = nil
    ) {
        self.id = id
        self.spaceID = spaceID
        self.projectKey = projectKey
        self.name = name
        self.bookmark = bookmark
        self.fingerprints = fingerprints
        self.projectSegment = projectSegment
    }

    /// The project a file belongs to, read from its path when this folder was
    /// granted as a library.
    func projectKey(forRelativePath relative: String) -> String {
        guard let projectSegment else { return projectKey }
        let parts = relative.split(separator: "/")
        guard parts.count > projectSegment + 1 else { return projectKey }
        return String(parts[projectSegment])
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
    /// A library folder legitimately holds thousands of files. The scan stays
    /// bounded, but at a size that fits a real corpus rather than one folder of
    /// notes; the import below it is what batches.
    private static let maximumFilesPerScan = 20_000

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
        projectSegment: Int? = nil,
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
            name: displayName(for: folder),
            bookmark: bookmark,
            projectSegment: projectSegment
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

    /// Seven folders named `throttle`, one per category, are seven identical rows
    /// in the sidebar. Carrying the parent tells them apart at a glance.
    static func displayName(for folder: URL) -> String {
        let parent = folder.deletingLastPathComponent().lastPathComponent
        guard !parent.isEmpty, parent != "/" else { return folder.lastPathComponent }
        return "\(parent)/\(folder.lastPathComponent)"
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
    ) throws -> (urls: [(url: URL, relative: String)], fingerprints: [String: String]) {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw ResearchVaultFolderSourceError.unavailable }
        var fingerprints: [String: String] = [:]
        var changed: [(url: URL, relative: String)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            guard ManualResearchFileImporter.supportedExtensions.contains(
                url.pathExtension.lowercased()
            ) else { continue }
            // Taking the tail by the root path's length assumed both spell the
            // same prefix, and they do not: the enumerator resolves /var to
            // /private/var, so a character or two of the parent's own name
            // survived into the key. Harmless while it was only an opaque
            // fingerprint key, wrong the moment the path names a project.
            guard let relative = Self.relativePath(of: url, under: folder) else { continue }
            let fingerprint = "\(values.fileSize ?? -1):\(values.contentModificationDate?.timeIntervalSince1970 ?? -1)"
            fingerprints[relative] = fingerprint
            if source.fingerprints[relative] != fingerprint {
                changed.append((url: url, relative: relative))
            }
            if fingerprints.count > maximumFilesPerScan {
                throw ResearchVaultFolderSourceError.tooManyFiles
            }
        }
        return (changed.sorted { $0.relative < $1.relative }, fingerprints)
    }

    /// The path of `url` beneath `root`, or nil when it is not beneath it.
    static func relativePath(of url: URL, under root: URL) -> String? {
        let file = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard file.count > base.count, Array(file.prefix(base.count)) == base else { return nil }
        return file.dropFirst(base.count).joined(separator: "/")
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
