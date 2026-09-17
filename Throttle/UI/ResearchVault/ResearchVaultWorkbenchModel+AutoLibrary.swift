import Foundation

extension ResearchVaultWorkbenchModel {

    /// Where research libraries live when nobody has to point at them: the
    /// DeepSearsh library (`<category>/<project>/…`) and a plain `~/Research`
    /// (`<project>/…`).
    nonisolated static var knownLibraryRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appending(path: "GitHub/DeepSearsh/library", directoryHint: .isDirectory),
            home.appending(path: "Research", directoryHint: .isDirectory)
        ]
    }

    static let autoLibraryDisabledKey = "researchVault.autoLibrary.disabled"
    private static let documentBackfillKey = "researchVault.documentBackfill.v1"

    /// Folders imported before this version sent receipts only, so their files
    /// were listed and unsearchable. One forced rescan per install repairs that.
    func backfillFolderDocumentsOnce(defaults: UserDefaults = .standard) {
        guard !isIsolatedHost, !defaults.bool(forKey: Self.documentBackfillKey) else { return }
        defaults.set(true, forKey: Self.documentBackfillKey)
        ResearchVaultFolderSourceStore.clearFingerprints(defaults: defaults)
        folderSources = ResearchVaultFolderSourceStore.load(defaults: defaults)
    }

    /// Connects every known research library that exists and is not connected
    /// yet, so research lands in its project's space without a folder picker.
    /// Outside the sandbox only: inside it, a folder the person did not pick
    /// cannot be granted, and must not be. Folders already inside a connected
    /// library are dropped — the library reads them.
    func autoConnectResearchLibraries(roots: [URL] = knownLibraryRoots,
                                      defaults: UserDefaults = .standard) {
        guard !isIsolatedHost, !ResearchVaultFolderSourceStore.isSandboxed,
              !defaults.bool(forKey: Self.autoLibraryDisabledKey) else { return }
        var connected = 0
        for root in roots where Self.isDirectory(root) {
            let rootPath = root.standardizedFileURL.path
            let sources = ResearchVaultFolderSourceStore.load(defaults: defaults)
            let paths = sources.map { ResearchVaultFolderSourceStore.recordedFolder($0)?.standardizedFileURL.path }
            guard !paths.contains(rootPath) else { continue }
            let segment = Self.projectSegment(under: root)
            guard !Self.projectNames(under: root, segment: segment).isEmpty else { continue }
            for (source, path) in zip(sources, paths) {
                if let path, path.hasPrefix(rootPath + "/") {
                    try? ResearchVaultFolderSourceStore.remove(id: source.id, defaults: defaults)
                }
            }
            if (try? ResearchVaultFolderSourceStore.add(folder: root, spaceID: ResearchVaultSpace.portfolio.id,
                                                       projectKey: root.lastPathComponent,
                                                       projectSegment: segment, defaults: defaults)) != nil {
                connected += 1
            }
        }
        guard connected > 0 else { return }
        folderSources = ResearchVaultFolderSourceStore.load(defaults: defaults)
        status = String(localized: "\(connected) research library(ies) connected automatically. Importing locally…")
    }

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
