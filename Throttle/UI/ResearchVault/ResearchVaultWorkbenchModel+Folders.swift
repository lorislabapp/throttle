import AppKit
import Observation
import ResearchVaultIngestion
import ResearchVaultIPCModel
import ResearchVaultModel
import ResearchVaultSynthesis
import ResearchVaultXPCClient
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

extension ResearchVaultWorkbenchModel {

    func chooseResearchFiles() async {
        guard !isIsolatedHost else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Add research files")
        panel.prompt = String(localized: "Add to Research Vault")
        panel.message = String(
            localized: "Files are read locally, sealed with their SHA-256, and quarantined for review."
        )
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ManualResearchFileImporter.supportedExtensions
            .sorted()
            .compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        await importResearchFiles(panel.urls)
    }

    func chooseFolderSource() async {
        guard !isIsolatedHost else { return }
        guard selectedSpace.kind == .project,
              let projectKey = selectedSpace.projectKeys.first else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Add a watched research folder")
        panel.prompt = String(localized: "Watch Folder")
        panel.message = String(
            // swiftlint:disable:next line_length
            localized: "New and revised supported files are imported locally and auto-approved for this explicitly trusted folder."
        )
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            for folder in panel.urls {
                _ = try ResearchVaultFolderSourceStore.add(
                    folder: folder,
                    spaceID: selectedSpace.id,
                    projectKey: projectKey
                )
            }
            folderSources = ResearchVaultFolderSourceStore.load()
            installFolderMonitor()
            status = String(localized: "Trusted folders added. Automatic local refresh is active.")
            await syncFolderSources(reportEmpty: false)
        } catch {
            status = String(localized: "The selected folder could not be persisted securely.")
        }
    }

    /// Grant a whole research library once instead of one folder per project.
    ///
    /// A corpus laid out as `<category>/<project>/…` costs one macOS permission
    /// per project otherwise — ninety of them here, against a ceiling of
    /// thirty-two watched folders, so the setup could not be completed at all.
    /// The tree is designated once and every file is routed to the Space its own
    /// path names. What protects the vault is unchanged: each file is still
    /// hashed, encrypted and held for review.
    func connectResearchLibrary() async {
        guard !isIsolatedHost else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Connect a research library")
        panel.prompt = String(localized: "Connect Library")
        panel.message = String(
            localized: """
            Pick the folder that holds every project's research. Throttle reads the \
            project each file belongs to from its path and creates the matching Spaces.
            """
        )
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let root = panel.url else { return }

        let segment = Self.projectSegment(under: root)
        let discovered = Self.projectNames(under: root, segment: segment)
        guard !discovered.isEmpty else {
            status = String(localized: "No project folders were found inside that library.")
            return
        }
        do {
            _ = try ResearchVaultFolderSourceStore.add(
                folder: root,
                spaceID: ResearchVaultSpace.portfolio.id,
                projectKey: root.lastPathComponent,
                projectSegment: segment
            )
            folderSources = ResearchVaultFolderSourceStore.load()
            let keys = Set(approvedReceipts.map(\.projectKey))
                .union(folderSources.map(\.projectKey))
                .union(discovered)
            spaces = ResearchVaultSpaceStore.load(projectKeys: keys)
            try? ResearchVaultSpaceStore.saveProjectKeys(keys)
            installFolderMonitor()
            status = String(
                localized: "Library connected: \(discovered.count) project(s). Importing locally…"
            )
            await syncFolderSources(reportEmpty: true)
        } catch {
            status = String(localized: "The selected library could not be persisted securely.")
        }
    }

    /// Which level names the project. A library whose immediate children are
    /// themselves folders of folders — categories — names projects one level
    /// deeper; a flat library names them at the top.
    static func projectSegment(under root: URL) -> Int {
        let children = directories(in: root)
        guard !children.isEmpty else { return 0 }
        let nested = children.filter { !directories(in: $0).isEmpty }
        return nested.count > children.count / 2 ? 1 : 0
    }

    static func projectNames(under root: URL, segment: Int) -> Set<String> {
        guard segment > 0 else { return Set(directories(in: root).map(\.lastPathComponent)) }
        return Set(directories(in: root).flatMap { directories(in: $0).map(\.lastPathComponent) })
    }

    static func directories(in url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []
        return contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    func removeFolderSource(_ id: UUID) {
        guard !isIsolatedHost else { return }
        do {
            try ResearchVaultFolderSourceStore.remove(id: id)
            folderSources = ResearchVaultFolderSourceStore.load()
            installFolderMonitor()
            status = String(localized: "Folder access removed. Imported evidence remains in the vault history.")
        } catch {
            status = String(localized: "Folder access could not be removed.")
        }
    }

    func syncFolderSources(reportEmpty: Bool = true) async {
        guard let client, serviceState == .enabled, !isBusy else { return }
        let sources = folderSources
        guard !sources.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        var imported = 0
        do {
            // One unreadable or oversized folder used to abort the loop, so a
            // single bad source silently kept every other folder unindexed.
            var failed = 0
            for source in sources {
                do {
                    imported += try await syncFolderSource(source, client: client)
                } catch {
                    failed += 1
                }
            }
            folderSources = ResearchVaultFolderSourceStore.load()
            if imported > 0 {
                approvedReceipts = try await loadApprovedReceipts(client: client)
                refreshSpaces()
                status = failed == 0
                    ? String(localized: "Trusted folders refreshed: \(imported) local document(s) approved.")
                    : String(
                        localized: "Refreshed \(imported) document(s); \(failed) folder(s) could not be read."
                    )
            } else if failed > 0 {
                status = String(localized: "\(failed) folder(s) could not be read; the previous index is unchanged.")
            } else if reportEmpty {
                status = String(localized: "Trusted folders are up to date.")
            }
        } catch {
            status = String(localized: "Automatic folder refresh failed closed; the previous index is unchanged.")
        }
    }

    func syncFolderSource(
        _ source: ResearchVaultFolderSource,
        client: ResearchVaultClient
    ) async throws -> Int {
        let folder = try ResearchVaultFolderSourceStore.resolve(source)
        guard folder.startAccessingSecurityScopedResource() else {
            throw ResearchVaultFolderSourceError.unavailable
        }
        defer { folder.stopAccessingSecurityScopedResource() }
        let scan = try ResearchVaultFolderSourceStore.changedFiles(for: source, at: folder)
        guard !scan.urls.isEmpty else { return 0 }

        // A folder holding more than one import's worth of files used to be
        // refused outright, which meant a real research folder — 37 files was
        // enough — never indexed at all and said so in a message about batch
        // size. Files are grouped by the project they belong to and imported a
        // batch at a time instead.
        var byProject: [String: [URL]] = [:]
        for file in scan.urls {
            byProject[source.projectKey(forRelativePath: file.relative), default: []].append(file.url)
        }

        var inserted = 0
        for (projectKey, files) in byProject.sorted(by: { $0.key < $1.key }) {
            try await client.admitProjects([projectKey])
            for chunk in files.vaultImportChunks(into: ManualResearchFileImporter.maximumDocuments) {
                let batch = try ManualResearchFileImporter(
                    files: chunk,
                    projectKey: projectKey
                ).load()
                let response = try await client.importReceipts(batch.receipts)
                let importedIDs = Set(batch.receipts.map(\.receiptID))
                let pendingIDs = try await client.quarantine().map(\.receiptID)
                    .filter(importedIDs.contains)
                if !pendingIDs.isEmpty {
                    _ = try await client.review(ids: pendingIDs, action: .approve)
                }
                inserted += response.insertedReceipts
            }
        }
        try ResearchVaultFolderSourceStore.markSynced(
            id: source.id,
            fingerprints: scan.fingerprints
        )
        return inserted
    }

    func installFolderMonitor() {
        guard !isIsolatedHost else { return }
        folderMonitor = ResearchVaultFolderMonitor(sources: folderSources) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.syncFolderSources(reportEmpty: false)
            }
        }
    }
}
