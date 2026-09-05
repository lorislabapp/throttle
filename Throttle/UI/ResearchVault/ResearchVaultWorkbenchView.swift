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

// The workbench deliberately co-locates its model and compact view until the
// Lot 5 UI decomposition; all executable methods remain linted individually.
// swiftlint:disable file_length

@MainActor
@Observable
final class ResearchVaultWorkbenchModel {
    var query = ""
    var results: [ResearchVaultContextItem] = []
    var contextBundle: ResearchVaultContextBundle?
    var synthesis: ResearchVaultSynthesisDraft?
    var serviceState = ResearchVaultServiceManager.state
    var health: ResearchVaultHealthResponse?
    var status = String(localized: "Research Vault is disabled.")
    var isBusy = false
    var inboxFolderName = ResearchVaultInboxBookmarkStore.configuredFolderName
    var migrationProjectKey = "notebooklm-import"
    var migrationManifest: NotebookLMMigrationManifest?
    var urlToImport = ""
    var pendingItems: [ResearchVaultQuarantineItem] = []
    var notebookLMNotebooks: [NotebookLMNotebookDescriptor] = []
    var selectedNotebookID: String?
    var notebookLMImportProgress = NotebookLMImportJob.Progress.idle
    var notebookLMSyncEnabled = false
    var approvedReceipts: [ResearchReceipt] = []
    var savedViews = ResearchVaultSavedViewStore.load()
    var selectedSavedViewID: UUID?
    var reasoningFacts: [ResearchVaultReasoningFactDTO] = []
    var reasoningDetail: ResearchVaultReasoningQueryResponse?
    var reasoningGeneration: Int64?
    var selectedReasoningFactID: String?
    var reasoningRelation = ResearchVaultReasoningRelationKind.dependsOn
    var reasoningSubject: ResearchVaultReasoningClaimReference?
    var reasoningObject: ResearchVaultReasoningClaimReference?
    var spaces = ResearchVaultSpaceStore.load(projectKeys: ["cheatcode", "throttle"])
    var selectedSpaceID = "project:throttle"
    var folderSources = ResearchVaultFolderSourceStore.load()
    /// A query that returned nothing and a vault nobody has searched yet look
    /// identical in the results area, and they need opposite words.
    var hasSearched = false
    var lastQuery = ""

    private let client: ResearchVaultClient?
    private var activeNotebookLMImportJob: NotebookLMImportJob?
    private var folderMonitor: ResearchVaultFolderMonitor?

    var selectedSpace: ResearchVaultSpace {
        spaces.first(where: { $0.id == selectedSpaceID })
            ?? spaces.first(where: { $0.id == "project:throttle" })
            ?? .portfolio
    }

    var selectedProjectKeys: [String] {
        if selectedSpace.kind == .portfolio {
            return spaces.filter { $0.kind == .project }.flatMap(\.projectKeys).sorted()
        }
        return selectedSpace.projectKeys
    }

    init(initialQuery: String = "") {
        query = initialQuery
        let identity = try? ResearchVaultCodeIdentity(
            signingIdentifier: "com.lorislab.throttle.research-vault-agent",
            teamIdentifier: "TDV6D5L785"
        )
        client = identity.map {
            ResearchVaultClient(
                queryServiceName: ResearchVaultServiceManager.queryServiceName,
                ownerServiceName: ResearchVaultServiceManager.ownerServiceName,
                serviceIdentity: $0
            )
        }
        refreshState()
        installFolderMonitor()
    }

    func refreshState() {
        serviceState = ResearchVaultServiceManager.state
        switch serviceState {
        case .unavailable: status = String(localized: "Research Vault is unavailable in this build.")
        case .disabled: status = String(localized: "Research Vault is disabled.")
        case .requiresApproval:
            status = String(localized: "Allow Research Vault in System Settings > Login Items.")
        case .enabled: status = String(localized: "Research Vault is enabled.")
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            try ResearchVaultServiceManager.setEnabled(enabled)
            refreshState()
            if enabled { Task { await checkHealth() } }
        } catch {
            refreshState()
            // The reason was dropped here, and the sentence that replaced it was
            // true of every possible failure — so a registration that macOS
            // refused looked exactly like one it had never been asked to make.
            status = String(localized: "macOS could not change the Research Vault service.")
                + " (\(error.localizedDescription))"
        }
    }

    func checkHealth() async {
        guard let client else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            health = try await client.health()
            pendingItems = try await client.quarantine()
            approvedReceipts = try await loadApprovedReceipts(client: client)
            refreshSpaces()
            status = String(localized: "Encrypted vault ready.")
            await refreshReasoningFacts(reportFailure: false)
        } catch {
            health = nil
            pendingItems = []
            approvedReceipts = []
            reasoningFacts = []
            reasoningDetail = nil
            reasoningGeneration = nil
            status = String(localized: "The signed Research Vault service is not reachable.")
        }
    }

    func selectSpace(_ id: String) {
        selectedSpaceID = id
        if let projectKey = selectedSpace.projectKeys.first {
            migrationProjectKey = projectKey
        }
        results = []
        contextBundle = nil
        synthesis = nil
        status = String(localized: "Searching in \(selectedSpace.name).")
    }

    private func refreshSpaces() {
        let projectKeys = Set(approvedReceipts.map(\.projectKey))
            .union(folderSources.map(\.projectKey))
            .union(["cheatcode", "throttle"])
        spaces = ResearchVaultSpaceStore.load(projectKeys: projectKeys)
        try? ResearchVaultSpaceStore.saveProjectKeys(projectKeys)
        if !spaces.contains(where: { $0.id == selectedSpaceID }) {
            selectedSpaceID = "project:throttle"
        }
    }

    func saveCurrentView() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let value = ResearchVaultSavedView(name: trimmed, query: trimmed)
        savedViews.insert(value, at: 0)
        do {
            try ResearchVaultSavedViewStore.save(savedViews)
            selectedSavedViewID = value.id
            status = String(localized: "Saved view created. It stores filters only, never corpus data.")
        } catch {
            savedViews.removeAll { $0.id == value.id }
            status = String(localized: "The saved view could not be stored.")
        }
    }

    func applySavedView() async {
        guard let value = savedViews.first(where: { $0.id == selectedSavedViewID }) else { return }
        query = value.query
        await search()
    }

    func loadQuarantine() async {
        guard let client else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            pendingItems = try await client.quarantine()
        } catch {
            pendingItems = []
            status = String(localized: "Quarantine refresh failed closed.")
        }
    }

}

extension ResearchVaultWorkbenchModel {
    var reasoningClaimReferences: [(reference: ResearchVaultReasoningClaimReference, title: String)] {
        let scope = Set(selectedProjectKeys)
        return approvedReceipts.filter { scope.contains($0.projectKey) }.flatMap { receipt in
            receipt.findings.enumerated().compactMap { index, finding in
                guard finding.status == .verified || finding.status == .supported else { return nil }
                return (
                    ResearchVaultReasoningClaimReference(
                        receiptID: receipt.receiptID,
                        findingIndex: index
                    ),
                    finding.claim
                )
            }
        }.sorted { left, right in
            if left.title != right.title { return left.title < right.title }
            if left.reference.receiptID != right.reference.receiptID {
                return left.reference.receiptID < right.reference.receiptID
            }
            return left.reference.findingIndex < right.reference.findingIndex
        }
    }

    var canRetractSelectedReasoningRelation: Bool {
        guard let selectedReasoningFactID,
              let fact = reasoningFacts.first(where: { $0.id == selectedReasoningFactID }) else {
            return false
        }
        return fact.asserted && ResearchVaultReasoningRelationKind(rawValue: fact.predicate) != nil
    }

    func refreshReasoningFacts(reportFailure: Bool = true) async {
        guard let client else { return }
        do {
            let response = try await client.reasoning(
                ResearchVaultReasoningQuery(kind: .facts, limit: 256)
            )
            reasoningFacts = response.facts
            reasoningGeneration = response.generation
            if selectedReasoningFactID == nil
                || !reasoningFacts.contains(where: { $0.id == selectedReasoningFactID }) {
                selectedReasoningFactID = reasoningFacts.first?.id
            }
        } catch {
            reasoningFacts = []
            reasoningDetail = nil
            reasoningGeneration = nil
            if reportFailure {
                status = String(localized: "Reasoning shadow is not initialized yet.")
            }
        }
    }

    func promoteSelectedReasoningRelation() async {
        guard let client, let reasoningSubject, let reasoningObject else { return }
        guard reasoningSubject != reasoningObject else {
            status = String(localized: "A claim cannot relate to itself.")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let response = try await client.promoteReasoningRelations([
                ResearchVaultReasoningRelation(
                    relation: reasoningRelation,
                    subject: reasoningSubject,
                    object: reasoningObject
                )
            ])
            reasoningGeneration = response.generation
            status = String(
                // swiftlint:disable:next line_length
                localized: "Reasoning shadow refreshed with \(response.baseFactCount) asserted facts and \(response.derivedFactCount) derived facts."
            )
            await refreshReasoningFacts(reportFailure: true)
            await loadReasoningDetail(.whatChanged)
        } catch {
            status = String(localized: "Relation promotion failed closed; no fact or rule changed.")
        }
    }

    func retractSelectedReasoningRelation() async {
        guard let client,
              let factID = selectedReasoningFactID,
              let fact = reasoningFacts.first(where: { $0.id == factID }),
              fact.asserted,
              ResearchVaultReasoningRelationKind(rawValue: fact.predicate) != nil else {
            status = String(localized: "Only an asserted reviewed relation can be retracted.")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let response = try await client.refreshReasoningRelations(removingFactIDs: [factID])
            reasoningGeneration = response.generation
            status = String(localized: "The selected relation was retracted from the reasoning shadow.")
            await refreshReasoningFacts(reportFailure: true)
            await loadReasoningDetail(.whatChanged)
        } catch {
            status = String(localized: "Relation retraction failed closed; no fact or rule changed.")
        }
    }

    func loadReasoningDetail(_ kind: ResearchVaultReasoningQueryKind) async {
        guard let client else { return }
        let factID = kind == .why || kind == .impacted ? selectedReasoningFactID : nil
        do {
            reasoningDetail = try await client.reasoning(
                ResearchVaultReasoningQuery(kind: kind, factID: factID, limit: 128)
            )
        } catch {
            reasoningDetail = nil
            status = String(localized: "The bounded reasoning explanation is unavailable.")
        }
    }
}

extension ResearchVaultWorkbenchModel {

    func review(_ receiptIDs: [String], action: ResearchVaultReviewRequest.Action) async {
        guard let client, !receiptIDs.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let processed = try await client.review(ids: receiptIDs, action: action)
            pendingItems = try await client.quarantine()
            health = try await client.health()
            switch action {
            case .approve:
                status = String(localized: "Approved \(processed) quarantined receipts.")
            case .reject:
                status = String(localized: "Rejected \(processed) quarantined receipts.")
            }
        } catch {
            status = String(localized: "Review failed closed; no unreviewed source became searchable.")
        }
    }

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let client else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let scope = selectedProjectKeys
            guard !scope.isEmpty else {
                status = String(localized: "This Space has no project source yet.")
                return
            }
            let bundle = try await client.search(query: trimmed, projectKeys: scope)
            contextBundle = bundle
            results = bundle.items
            synthesis = nil
            hasSearched = true
            lastQuery = trimmed
            status = bundle.items.isEmpty
                ? String(localized: "No authorized local source matched.")
                : String(localized: "Results come from local sources; generated text is never evidence.")
        } catch {
            results = []
            contextBundle = nil
            synthesis = nil
            status = String(localized: "Search failed closed. Check service approval and signing.")
        }
    }

    func synthesizeOnDevice() async {
        guard let contextBundle, !contextBundle.items.isEmpty else { return }
        guard EmbeddedModelRuntime.isInstalled else {
            status = String(localized: "Install the embedded Qwen model in AI settings first.")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let executor = try ResearchVaultSynthesisExecutor(
                sameDevice: ResearchVaultEmbeddedSynthesisProvider()
            )
            let outcome = try await executor.execute(
                ResearchVaultSynthesisRequest(
                    task: .summarize,
                    objective: query,
                    context: contextBundle
                ),
                capabilities: ResearchVaultSynthesisCapabilities(
                    sameDeviceAvailable: true,
                    trustedPrivateServerAvailable: false,
                    trustedPrivateServerAuthenticated: false
                )
            )
            synthesis = outcome.draft
            status = String(localized: "On-device draft validated against known citation identifiers.")
        } catch {
            synthesis = nil
            status = String(localized: "Local synthesis failed closed; the cited sources remain available.")
        }
    }

}

extension ResearchVaultWorkbenchModel {

    func chooseResearchFiles() async {
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

    func removeFolderSource(_ id: UUID) {
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
            for source in sources {
                imported += try await syncFolderSource(source, client: client)
            }
            folderSources = ResearchVaultFolderSourceStore.load()
            if imported > 0 {
                approvedReceipts = try await loadApprovedReceipts(client: client)
                refreshSpaces()
                status = String(localized: "Trusted folders refreshed: \(imported) local document(s) approved.")
            } else if reportEmpty {
                status = String(localized: "Trusted folders are up to date.")
            }
        } catch ResearchVaultFolderSourceError.tooManyFiles {
            status = String(localized: "A folder has more than 32 changes. Reduce the batch before automatic refresh.")
        } catch {
            status = String(localized: "Automatic folder refresh failed closed; the previous index is unchanged.")
        }
    }

    private func syncFolderSource(
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
        guard scan.urls.count <= 32 else { throw ResearchVaultFolderSourceError.tooManyFiles }
        let batch = try ManualResearchFileImporter(
            files: scan.urls,
            projectKey: source.projectKey
        ).load()
        let response = try await client.importReceipts(batch.receipts)
        let importedIDs = Set(batch.receipts.map(\.receiptID))
        let pendingIDs = try await client.quarantine().map(\.receiptID)
            .filter(importedIDs.contains)
        if !pendingIDs.isEmpty {
            _ = try await client.review(ids: pendingIDs, action: .approve)
        }
        try ResearchVaultFolderSourceStore.markSynced(
            id: source.id,
            fingerprints: scan.fingerprints
        )
        return response.insertedReceipts
    }

    private func installFolderMonitor() {
        folderMonitor = ResearchVaultFolderMonitor(sources: folderSources) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.syncFolderSources(reportEmpty: false)
            }
        }
    }

    func importResearchFiles(_ urls: [URL]) async {
        guard let client else { return }
        let projectKey = migrationProjectKey.trimmingCharacters(in: .whitespacesAndNewlines)
        isBusy = true
        defer { isBusy = false }
        let scopedURLs = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        defer {
            for (url, accessed) in scopedURLs where accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let batch = try ManualResearchFileImporter(
                files: urls,
                projectKey: projectKey
            ).load()
            var inserted = 0
            var present = 0
            for receipt in batch.receipts {
                let response = try await client.importReceipts([receipt])
                inserted += response.insertedReceipts
                present += response.alreadyPresentReceipts
            }
            await checkHealth()
            let shortHash = batch.aggregateSHA256.prefix(12)
            status = String(
                localized: "Research files: \(inserted) quarantined, \(present) already present · SHA-256 \(shortHash)."
            )
        } catch ManualResearchFileImportError.invalidProjectKey {
            status = String(localized: "Project key must use lowercase letters, numbers, dots, dashes or underscores.")
        } catch ManualResearchFileImportError.tooManyDocuments {
            status = String(localized: "Select at most 32 research files per import.")
        } catch ManualResearchFileImportError.unsupportedExtension {
            status = String(localized: "One selected file type is not supported.")
        } catch {
            status = String(
                localized: "Research import failed closed. No source file was moved, deleted or uploaded."
            )
        }
    }

    func importReceiptFiles() async {
        guard let client else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import sealed research receipts")
        panel.prompt = String(localized: "Import")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK else { return }
        let urls = Array(panel.urls.prefix(ResearchVaultIPCContract.maximumReceiptsPerRequest))
        isBusy = true
        defer { isBusy = false }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let receipts = try urls.map { url in
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true,
                      let size = values.fileSize,
                      size <= ResearchVaultIPCContract.maximumOwnerRequestBytes else {
                    throw ResearchVaultClientError.invalidConfiguration
                }
                return try decoder.decode(ResearchReceipt.self, from: Data(contentsOf: url))
            }
            let response = try await client.importReceipts(receipts)
            await checkHealth()
            status = String(
                localized: "Imported \(response.insertedReceipts); already present \(response.alreadyPresentReceipts)."
            )
        } catch {
            status = String(
                localized: "Import rejected. Files must be valid sealed receipts within the endpoint grant."
            )
        }
    }

    func chooseInboxFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a Research Vault Inbox")
        panel.prompt = String(localized: "Choose Inbox")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            try ResearchVaultInboxBookmarkStore.save(folder: folder)
            inboxFolderName = folder.lastPathComponent
            status = String(localized: "Inbox connected. Sync remains explicit and local.")
        } catch {
            status = String(localized: "The Inbox bookmark could not be saved.")
        }
    }

    func syncInbox() async {
        guard let client else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let receipts = try ResearchVaultInboxBookmarkStore.loadReceipts()
            guard !receipts.isEmpty else {
                status = String(localized: "Inbox contains no JSON receipt.")
                return
            }
            let response = try await client.importReceipts(receipts)
            await checkHealth()
            status = String(
                // swiftlint:disable:next line_length
                localized: "Inbox synced: \(response.insertedReceipts) imported, \(response.alreadyPresentReceipts) already present."
            )
        } catch ResearchVaultInboxError.tooManyReceipts {
            status = String(localized: "Inbox has more than 32 receipts. Archive a batch before syncing.")
        } catch {
            status = String(localized: "Inbox sync failed closed; no file was moved or deleted.")
        }
    }

    func importNotebookLMExport() async {
        guard let client else { return }
        let projectKey = migrationProjectKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose an exported NotebookLM folder")
        panel.prompt = String(localized: "Import Locally")
        // swiftlint:disable:next line_length
        panel.message = String(localized: "Throttle reads supported documents locally. It never signs in to Google or uploads this folder.")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        isBusy = true
        defer { isBusy = false }
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        do {
            let batch = try NotebookLMMigrationImporter(root: folder, projectKey: projectKey).load()
            var inserted = 0
            var present = 0
            // One source per request keeps the signed owner endpoint below its
            // strict 1 MiB cap even for the largest accepted migration file.
            for receipt in batch.receipts {
                let response = try await client.importReceipts([receipt])
                inserted += response.insertedReceipts
                present += response.alreadyPresentReceipts
            }
            migrationManifest = batch.manifest
            await checkHealth()
            status = String(
                // swiftlint:disable:next line_length
                localized: "NotebookLM migration: \(inserted) imported, \(present) already present · manifest \(batch.manifest.aggregateSHA256.prefix(12))."
            )
        } catch NotebookLMMigrationError.invalidProjectKey {
            status = String(localized: "Project key must use lowercase letters, numbers, dots, dashes or underscores.")
        } catch NotebookLMMigrationError.emptyExport {
            status = String(localized: "No supported NotebookLM export document was found.")
        } catch {
            migrationManifest = nil
            status = String(localized: "Migration failed closed. No source file was moved, deleted or uploaded.")
        }
    }

}

extension ResearchVaultWorkbenchModel {

    func loadNotebookLMNotebooks() async {
        guard notebookLMSyncEnabled else {
            status = String(localized: "Enable explicit NotebookLM export for this session first.")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let gateway = try NotebookLMGatewayClient()
            notebookLMNotebooks = try await gateway.listNotebooks()
            if selectedNotebookID == nil { selectedNotebookID = notebookLMNotebooks.first?.id }
            status = notebookLMNotebooks.isEmpty
                ? String(localized: "No NotebookLM notebook is available from the configured gateway.")
                : String(localized: "Choose a NotebookLM notebook, then start the explicit local import.")
        } catch {
            notebookLMNotebooks = []
            status = String(localized: "NotebookLM listing failed closed. No source was exported.")
        }
    }

    func importSelectedNotebookLM() async {
        guard notebookLMSyncEnabled,
              let notebook = notebookLMNotebooks.first(where: { $0.id == selectedNotebookID }),
              let client else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a staging folder for the NotebookLM import")
        panel.prompt = String(localized: "Start Import")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        isBusy = true
        defer { isBusy = false }
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        do {
            let job = NotebookLMImportJob(gateway: try NotebookLMGatewayClient())
            activeNotebookLMImportJob = job
            let monitor = Task { @MainActor in
                while !Task.isCancelled {
                    notebookLMImportProgress = await job.progress
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer {
                monitor.cancel()
                activeNotebookLMImportJob = nil
            }
            notebookLMImportProgress = try await job.run(
                notebook: notebook,
                stagingFolder: folder
            )
            guard notebookLMImportProgress.phase == .complete else {
                status = String(localized: "NotebookLM import paused. Select the same staging folder to resume.")
                return
            }
            let (inserted, present) = try await quarantineStagedImport(
                folder: folder,
                client: client
            )
            await checkHealth()
            status = String(
                localized: "NotebookLM import staged and quarantined: \(inserted) new, \(present) already present."
            )
        } catch {
            status = String(localized: "NotebookLM import failed closed. The checkpoint remains resumable.")
        }
    }

    func pauseNotebookLMImport() async {
        await activeNotebookLMImportJob?.requestPause()
        status = String(localized: "Pause requested; the current source will finish safely.")
    }

    private func quarantineStagedImport(
        folder: URL,
        client: ResearchVaultClient
    ) async throws -> (inserted: Int, present: Int) {
        let batch = try NotebookLMMigrationImporter(
            root: folder,
            projectKey: migrationProjectKey,
            sensitivity: .internal
        ).load()
        var inserted = 0
        var present = 0
        for receipt in batch.receipts {
            let response = try await client.importReceipts([receipt])
            inserted += response.insertedReceipts
            present += response.alreadyPresentReceipts
        }
        return (inserted, present)
    }

    func importURL() async {
        guard let client else { return }
        let value = urlToImport.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), !value.isEmpty else {
            status = String(localized: "Enter a valid HTTPS URL.")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let receipt = try await ResearchVaultURLIntake.fetch(
                url: url,
                projectKey: migrationProjectKey,
                sensitivity: .confidential
            )
            let response = try await client.importReceipts([receipt])
            urlToImport = ""
            await checkHealth()
            status = String(
                // swiftlint:disable:next line_length
                localized: "URL quarantined: \(response.insertedReceipts) imported, \(response.alreadyPresentReceipts) already present."
            )
        } catch {
            status = String(
                localized: "URL import failed closed. Use one public HTTPS text or HTML page under 512 KiB."
            )
        }
    }

    func saveMigrationManifest() {
        guard let migrationManifest, let data = try? migrationManifest.encoded() else { return }
        let panel = NSSavePanel()
        panel.title = String(localized: "Save NotebookLM migration manifest")
        panel.nameFieldStringValue = "research-vault-notebooklm-manifest.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: [.atomic])
            status = String(localized: "Migration manifest saved with source hashes and aggregate integrity hash.")
        } catch {
            status = String(localized: "The migration manifest could not be saved.")
        }
    }

    func exportMarkdown() async {
        guard let client else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let receipts = try await loadApprovedReceipts(client: client)
            guard !receipts.isEmpty else {
                status = String(localized: "No approved receipt is available to export.")
                return
            }
            let documents = ResearchVaultMarkdownExporter.export(receipts)
            guard let folder = chooseMarkdownExportFolder() else { return }
            guard try writeMarkdown(documents, to: folder) else {
                status = String(localized: "Export stopped: a destination file already exists.")
                return
            }
            status = String(localized: "Exported \(documents.count) approved receipts as derived Markdown.")
        } catch {
            status = String(localized: "Markdown export failed closed; no vault data was changed.")
        }
    }

    private func loadApprovedReceipts(client: ResearchVaultClient) async throws -> [ResearchReceipt] {
        var receipts: [ResearchReceipt] = []
        var cursor: String?
        var seenCursors = Set<String>()
        repeat {
            let page = try await client.exportReceipts(afterReceiptID: cursor, limit: 8)
            receipts.append(contentsOf: page.receipts)
            guard receipts.count <= 4_096 else { throw ResearchVaultClientError.invalidResponse }
            cursor = page.nextReceiptID
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw ResearchVaultClientError.invalidResponse
            }
        } while cursor != nil
        return receipts
    }

    private func chooseMarkdownExportFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a folder for the Markdown export")
        panel.prompt = String(localized: "Export")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func writeMarkdown(
        _ documents: [ResearchVaultMarkdownDocument],
        to folder: URL
    ) throws -> Bool {
        let destinations = documents.map {
            folder.appendingPathComponent($0.filename, isDirectory: false)
        }
        guard destinations.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else {
            return false
        }
        var created: [URL] = []
        do {
            for (document, destination) in zip(documents, destinations) {
                try Data(document.content.utf8).write(to: destination, options: [.atomic])
                created.append(destination)
            }
        } catch {
            created.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
        return true
    }
}

// Kept as one view so keyboard focus and quarantine confirmation state remain local.
// swiftlint:disable:next type_body_length
struct ResearchVaultWorkbenchView: View {
    let onBack: () -> Void
    @State private var model: ResearchVaultWorkbenchModel
    @State private var showBulkRejectConfirmation = false
    @State private var showReasoningPromotionConfirmation = false
    @State private var showReasoningRetractionConfirmation = false
    @State private var pane = WorkbenchPane.evidence
    @State private var showAddToVault = false

    private enum WorkbenchPane: String, CaseIterable, Identifiable {
        case evidence = "Evidence"
        case sources = "Sources"
        case claims = "Claims"
        case timeline = "Timeline"
        case revisions = "Revisions"
        case reasoning = "Reasoning"

        var id: String { rawValue }

        var localizedTitle: LocalizedStringKey {
            switch self {
            case .evidence: "Evidence"
            case .sources: "Sources"
            case .claims: "Claims"
            case .timeline: "Timeline"
            case .revisions: "Revisions"
            case .reasoning: "Reasoning"
            }
        }
    }

    init(initialQuery: String = "", onBack: @escaping () -> Void) {
        self.onBack = onBack
        _model = State(initialValue: ResearchVaultWorkbenchModel(initialQuery: initialQuery))
    }

    var body: some View {
        HStack(spacing: 0) {
            spaceSidebar
                .frame(width: 240)
            Divider()
            VStack(spacing: 0) {
                titleBar
                Divider()
                searchBlock
                mainContent
                Divider()
                trustLine
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 940, idealWidth: 1_100, minHeight: 620, idealHeight: 700)
        .sheet(isPresented: $showAddToVault) { addToVaultSheet }
        .task { if model.serviceState == .enabled { await model.checkHealth() } }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled else { return }
                await model.syncFolderSources(reportEmpty: false)
            }
        }
        .confirmationDialog(
            "Promote this reviewed relation?",
            isPresented: $showReasoningPromotionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Promote and refresh shadow") {
                Task { await model.promoteSelectedReasoningRelation() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the selected typed relation is promoted. Source text cannot install rules or widen access.")
        }
        .confirmationDialog(
            "Retract this asserted relation?",
            isPresented: $showReasoningRetractionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Retract selected relation", role: .destructive) {
                Task { await model.retractSelectedReasoningRelation() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Direct evidence and derived facts cannot be retracted from this control.")
        }
    }

    // MARK: - Setup progress

    /// The three steps between a fresh install and a searchable vault. They are
    /// what the content area shows until every one of them is done, because a
    /// vault with nothing in it has nothing else worth saying.
    private var vaultIsOn: Bool { model.serviceState == .enabled }
    private var loginItemsApproved: Bool { model.serviceState != .requiresApproval }

    private var spaceFolders: [ResearchVaultFolderSource] {
        model.folderSources.filter {
            model.selectedSpace.kind == .portfolio || $0.spaceID == model.selectedSpaceID
        }
    }

    private var hasASource: Bool {
        !spaceFolders.isEmpty || (model.health?.documentCount ?? 0) > 0
    }

    private var setupComplete: Bool { vaultIsOn && loginItemsApproved && hasASource }

    // MARK: - Chrome

    private var titleBar: some View {
        HStack(spacing: 14) {
            Button(action: onBack) { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            Text("Research Vault")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            if model.isBusy { ProgressView().controlSize(.small) }
            Button("Add to vault…") { showAddToVault = true }
                .disabled(!vaultIsOn)
                .help(vaultIsOn
                    ? String(localized: "Every way to put research into this vault")
                    : String(localized: "Turn the vault on first"))
            if vaultIsOn {
                Button("Turn off") { model.setEnabled(false) }
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 52)
    }

    private var searchBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text(model.selectedSpace.name)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Search scope: \(model.selectedSpace.name)")
                TextField("Ask your past research…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .onSubmit { Task { await model.search() } }
                    .disabled(!setupComplete)
                if model.hasSearched {
                    Text("\(model.results.count) excerpts")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.09))
            )

            if !setupComplete {
                Text("Search turns on at step 3.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if !model.pendingItems.isEmpty {
                Text("Nothing is searchable until you approve the documents below.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                secondaryActions
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 24)
    }

    /// Both actions state their own reason when they cannot run. A control that
    /// greys out without a word is the single complaint this window earned most.
    private var secondaryActions: some View {
        HStack(spacing: 22) {
            reasonedAction(
                "Synthesize on this Mac",
                reason: model.results.isEmpty ? String(localized: "needs at least one excerpt") : nil
            ) {
                Task { await model.synthesizeOnDevice() }
            }
            reasonedAction(
                "Save view",
                reason: model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? String(localized: "nothing to save yet") : nil
            ) {
                model.saveCurrentView()
            }
            if !model.savedViews.isEmpty {
                Picker("Saved View", selection: $model.selectedSavedViewID) {
                    Text("Saved views").tag(Optional<UUID>.none)
                    ForEach(model.savedViews) { view in
                        Text(view.name).tag(Optional(view.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 170)
                Button("Apply") { Task { await model.applySavedView() } }
                    .disabled(model.selectedSavedViewID == nil)
            }
            Spacer()
        }
        .frame(minHeight: 36)
    }

    @ViewBuilder
    private func reasonedAction(
        _ title: LocalizedStringKey,
        reason: String?,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Button(title, action: action)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(reason == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .disabled(reason != nil)
            if let reason {
                Text("— \(reason)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(reason ?? "")
    }

    private var trustLine: some View {
        HStack(spacing: 0) {
            Text(vaultIsOn
                ? String(localized: "Encrypted vault on")
                : String(localized: "Encrypted vault off"))
            if let health = model.health {
                Text(" · \(health.documentCount) documents · \(health.receiptCount) receipts")
                if !model.pendingItems.isEmpty {
                    Text(" · \(model.pendingItems.count) in quarantine")
                }
                Text(" · ")
                Text("SQLCipher \(health.cipherVersion)").font(.system(size: 11.5, design: .monospaced))
            }
            Spacer()
            Text(model.status).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 11.5).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 28)
        .frame(minHeight: 44)
    }

    // MARK: - Content

    @ViewBuilder
    private var mainContent: some View {
        if !setupComplete {
            setupChecklist
        } else if !model.pendingItems.isEmpty {
            quarantineSection
        } else if model.hasSearched && model.results.isEmpty && pane == .evidence {
            emptyResults
        } else {
            if pane == .evidence, let synthesis = model.synthesis {
                synthesisBlock(synthesis)
            }
            workbenchContent
        }
    }

    private var setupChecklist: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Three steps to a searchable vault")
                .font(.system(size: 24, weight: .bold))
                .padding(.bottom, 22)

            checklistStep(
                ChecklistStep(
                    number: 1,
                    done: vaultIsOn,
                    live: !vaultIsOn,
                    title: String(localized: "Turn on the vault"),
                    detail: String(
                        localized: """
                        A separate signed helper, the Throttle Vault Agent, starts on this Mac. \
                        Nothing leaves the machine.
                        """
                    ),
                    doneTitle: String(localized: "Vault is on")
                )
            ) {
                Button("Turn on the vault") { model.setEnabled(true) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

            checklistStep(
                ChecklistStep(
                    number: 2,
                    done: vaultIsOn && loginItemsApproved,
                    live: vaultIsOn && !loginItemsApproved,
                    title: String(localized: "Allow it in Login Items, if macOS asks"),
                    detail: String(localized: "macOS is holding the helper until you approve it."),
                    doneTitle: String(localized: "Allowed in Login Items")
                )
            ) {
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

            checklistStep(
                ChecklistStep(
                    number: 3,
                    done: hasASource,
                    live: vaultIsOn && loginItemsApproved && !hasASource,
                    title: model.selectedSpace.kind == .project
                        ? String(localized: "Add a folder to \(model.selectedSpace.name)")
                        : String(localized: "Add a folder to a space"),
                    detail: stepThreeDetail,
                    doneTitle: String(localized: "Sources connected"),
                    isLast: true
                )
            ) {
                HStack(spacing: 10) {
                    Button("Watch a folder…") { Task { await model.chooseFolderSource() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.selectedSpace.kind != .project)
                    Button("Other ways in…") { showAddToVault = true }
                        .controlSize(.large)
                }
            }

            Spacer()
        }
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 40)
        .padding(.top, 40)
    }

    /// One step of the setup checklist. Grouped into a value rather than eight
    /// parameters so the call sites read as the three steps they describe.
    private struct ChecklistStep {
        let number: Int
        let done: Bool
        let live: Bool
        let title: String
        let detail: String
        let doneTitle: String
        var isLast = false
    }

    @ViewBuilder
    private func checklistStep<Action: View>(
        _ step: ChecklistStep,
        @ViewBuilder action: () -> Action
    ) -> some View {
        let (number, done, live) = (step.number, step.done, step.live)
        let (title, detail, doneTitle, isLast) = (step.title, step.detail, step.doneTitle, step.isLast)
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(live ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                    .frame(width: 28, height: 28)
                Text(done ? "✓" : "\(number)")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(live ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(done ? doneTitle : title)
                    .font(.system(size: done ? 13 : 17, weight: done ? .medium : .semibold))
                    .foregroundStyle(done || live ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                if !done {
                    Text(detail)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if live { action() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, done ? 12 : 18)
        .overlay(alignment: .bottom) {
            if !isLast { Divider() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(done
            ? String(localized: "Step \(number), done: \(doneTitle)")
            : String(localized: "Step \(number): \(title)"))
    }

    private var stepThreeDetail: String {
        guard model.selectedSpace.kind == .project else {
            return String(
                localized: """
                Pick a project in the sidebar first — Portfolio is a read-only roll-up of \
                the other spaces and holds no folders of its own.
                """
            )
        }
        return String(localized: "Pick the folder where this project’s research already lives.")
    }

    private var emptyResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Nothing in \(model.selectedSpace.name) matches “\(model.lastQuery)”.")
                .font(.system(size: 24, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(searchedCountSentence)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                if model.selectedSpace.kind == .project {
                    Button("Search all of Portfolio instead") {
                        model.selectSpace(ResearchVaultSpace.portfolio.id)
                        Task { await model.search() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Button("Try fewer words") { model.query = "" }
                    .controlSize(.large)
            }
            .padding(.top, 26)
            Spacer()
        }
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 40)
        .padding(.top, 44)
    }

    /// Only ever states a number the vault actually reported.
    private var searchedCountSentence: String {
        guard let documents = model.health?.documentCount, documents > 0 else {
            return String(localized: "This space has no approved documents yet.")
        }
        return String(localized: "\(documents) documents were searched.")
    }

    private func synthesisBlock(_ synthesis: ResearchVaultSynthesisDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                Text("SYNTHESIS · LOCAL")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.primary.opacity(0.2))
                    )
                VStack(alignment: .leading, spacing: 6) {
                    Text(synthesis.answer)
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                    Text("Citations: \(synthesis.citationIDs.joined(separator: ", "))")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let uncertainty = synthesis.uncertainty, !uncertainty.isEmpty {
                        Text("Uncertainty: \(uncertainty)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Add to vault

    private var addToVaultSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add to \(model.selectedSpace.name)")
                    .font(.system(size: 19, weight: .bold))
                Text("Everything is hashed, encrypted and held in quarantine until you approve it.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sheetSectionHeader("Everyday")
                    everydayWays
                    sheetSectionHeader("Occasional")
                    occasionalWays
                }
                .padding(.horizontal, 28)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { showAddToVault = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 620)
    }

    private func sheetSectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var everydayWays: some View {
        everydayRow(
            title: String(localized: "Watch a folder"),
            hint: String(
                localized: "Throttle keeps it in sync. Best for a research folder you already keep."
            ),
            action: String(localized: "Choose folder…"),
            reason: model.selectedSpace.kind == .project
                ? nil : String(localized: "pick a project space first")
        ) {
            showAddToVault = false
            Task { await model.chooseFolderSource() }
        }
        everydayRow(
            title: String(localized: "Add files"),
            hint: String(localized: "Drop in individual notes, PDFs or exports."),
            action: String(localized: "Choose files…"),
            reason: model.migrationProjectKey.isEmpty
                ? String(localized: "needs a project key") : nil
        ) {
            showAddToVault = false
            Task { await model.chooseResearchFiles() }
        }
    }

    @ViewBuilder
    private var occasionalWays: some View {
        occasionalRow(
            title: String(localized: "Import sealed receipts"),
            hint: String(localized: "Signed .receipt files from another Mac."),
            action: String(localized: "Choose…"),
            reason: nil
        ) {
            showAddToVault = false
            Task { await model.importReceiptFiles() }
        }
        occasionalRow(
            title: String(localized: "Inbox folder and sync"),
            hint: model.inboxFolderName.map {
                String(localized: "Currently \($0). Throttle empties it on demand.")
            } ?? String(localized: "A drop folder Throttle empties on demand."),
            action: model.inboxFolderName == nil
                ? String(localized: "Set up…") : String(localized: "Sync now"),
            reason: nil
        ) {
            if model.inboxFolderName == nil {
                model.chooseInboxFolder()
            } else {
                Task { await model.syncInbox() }
            }
        }
        occasionalRow(
            title: String(localized: "Import a NotebookLM export"),
            hint: String(localized: "Local file, no Google connection."),
            action: String(localized: "Choose…"),
            reason: model.migrationProjectKey.isEmpty
                ? String(localized: "needs a project key") : nil
        ) {
            showAddToVault = false
            Task { await model.importNotebookLMExport() }
        }
        occasionalRow(
            title: String(localized: "Export to Markdown"),
            hint: String(localized: "One .md or a folder of them."),
            action: String(localized: "Choose…"),
            reason: nil
        ) {
            showAddToVault = false
            Task { await model.exportMarkdown() }
        }
        urlRow
        notebookLMRow
    }

    private var urlRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            occasionalRow(
                title: String(localized: "Import one URL"),
                hint: String(localized: "HTTPS, single page, quarantined."),
                action: String(localized: "Import"),
                reason: model.urlToImport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? String(localized: "paste a URL below") : nil
            ) {
                Task { await model.importURL() }
            }
            TextField("https://example.com/research", text: $model.urlToImport)
                .textFieldStyle(.roundedBorder)
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var notebookLMRow: some View {
        occasionalRow(
            title: String(localized: "List NotebookLM notebooks"),
            hint: String(localized: "Explicit read/export only; resumes where it stopped."),
            action: model.notebookLMSyncEnabled
                ? String(localized: "List…") : String(localized: "Allow first"),
            reason: model.notebookLMSyncEnabled
                ? nil : String(localized: "turn on the export permission below")
        ) {
            Task { await model.loadNotebookLMNotebooks() }
        }
        Toggle("Allow NotebookLM export", isOn: $model.notebookLMSyncEnabled)
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .padding(.bottom, 8)
            .help("Opt in for this session. Throttle never exports in the background.")
        if !model.notebookLMNotebooks.isEmpty {
            HStack(spacing: 8) {
                Picker("Notebook", selection: $model.selectedNotebookID) {
                    ForEach(model.notebookLMNotebooks) { notebook in
                        Text("\(notebook.title) (\(notebook.sourceCount))")
                            .tag(Optional(notebook.id))
                    }
                }
                .labelsHidden()
                Button(
                    model.notebookLMImportProgress.completed > 0
                        ? String(localized: "Resume import") : String(localized: "Start import")
                ) {
                    Task { await model.importSelectedNotebookLM() }
                }
                .disabled(model.selectedNotebookID == nil || model.isBusy)
                if model.notebookLMImportProgress.phase == .exporting {
                    Button("Pause") { Task { await model.pauseNotebookLMImport() } }
                }
            }
            .padding(.bottom, 8)
            if model.notebookLMImportProgress.total > 0 {
                ProgressView(
                    value: Double(model.notebookLMImportProgress.completed),
                    total: Double(model.notebookLMImportProgress.total)
                )
                .padding(.bottom, 10)
            }
        }
        if model.migrationManifest != nil {
            Button("Save integrity manifest…") { model.saveMigrationManifest() }
                .padding(.bottom, 10)
        }
    }

    private func everydayRow(
        title: String,
        hint: String,
        action: String,
        reason: String?,
        perform: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(reason.map { "\(hint) — \($0)" } ?? hint)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action, action: perform)
                .buttonStyle(.borderedProminent)
                .disabled(reason != nil || !vaultIsOn)
                .fixedSize()
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Divider() }
        .accessibilityHint(reason ?? "")
    }

    private func occasionalRow(
        title: String,
        hint: String,
        action: String,
        reason: String?,
        perform: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(reason.map { "\(hint) — \($0)" } ?? hint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action, action: perform)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(
                    reason == nil && vaultIsOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary)
                )
                .disabled(reason != nil || !vaultIsOn)
                .fixedSize()
        }
        .frame(minHeight: 44)
        .overlay(alignment: .top) { Divider() }
        .accessibilityHint(reason ?? "")
    }

    // MARK: - Sidebar

    private var facetCounts: [WorkbenchPane: Int] {
        let receipts = scopedApprovedReceipts
        return [
            .evidence: model.results.count,
            .sources: ResearchVaultWorkbenchProjection.sources(receipts: receipts).count,
            .claims: ResearchVaultWorkbenchProjection.claims(receipts: receipts).count,
            .timeline: receipts.count,
            .revisions: ResearchVaultWorkbenchProjection.revisions(receipts: receipts).count,
            .reasoning: model.reasoningFacts.count
        ]
    }

    private var spaceSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sidebarHeader("Spaces")
                ForEach(model.spaces) { space in
                    spaceRow(space)
                    if space.id == model.selectedSpaceID && space.kind == .project {
                        selectedSpaceFolders
                    }
                }

                sidebarHeader(model.hasSearched ? "Facets · this query" : "Facets")
                ForEach(WorkbenchPane.allCases) { facet in
                    facetRow(facet)
                }

                Spacer(minLength: 12)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
        .background(.quaternary.opacity(0.2))
    }

    private func sidebarHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func spaceRow(_ space: ResearchVaultSpace) -> some View {
        let selected = space.id == model.selectedSpaceID
        let waiting = selected ? model.pendingItems.count : 0
        return Button {
            model.selectSpace(space.id)
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .frame(width: 6, height: 6)
                Text(space.name).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
                if waiting > 0 {
                    Text("\(waiting) waiting")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The folders of the selected space, and the control that adds one — in the
    /// space they belong to, rather than behind an unlabelled icon in a header.
    @ViewBuilder
    private var selectedSpaceFolders: some View {
        if spaceFolders.isEmpty {
            Text("No folders yet.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.leading, 25)
                .padding(.vertical, 2)
        }
        ForEach(spaceFolders) { source in
            HStack(spacing: 6) {
                Text(source.name)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
                Button {
                    model.removeFolderSource(source.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(source.name)")
            }
            .padding(.leading, 25)
            .padding(.trailing, 10)
            .frame(minHeight: 36)
        }
        Button {
            Task { await model.chooseFolderSource() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text("Add folder to \(model.selectedSpace.name)…")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tint)
            .padding(.leading, 25)
            .padding(.trailing, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!vaultIsOn)
        .help(vaultIsOn
            ? String(localized: "Watch a folder for this space")
            : String(localized: "Turn the vault on first"))
    }

    private func facetRow(_ facet: WorkbenchPane) -> some View {
        let selected = pane == facet
        let count = facetCounts[facet] ?? 0
        return Button {
            pane = facet
        } label: {
            HStack {
                Text(facet.localizedTitle)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
                Text(model.hasSearched || count > 0 ? "\(count)" : "—")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(minHeight: 36)
            .background(
                selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var scopedApprovedReceipts: [ResearchReceipt] {
        let scope = Set(model.selectedProjectKeys)
        return model.approvedReceipts.filter { scope.contains($0.projectKey) }
    }

    @ViewBuilder
    private var workbenchContent: some View {
        switch pane {
        case .evidence where model.results.isEmpty:
                ContentUnavailableView(
                    "Source-first local research",
                    systemImage: "lock.doc",
                    // swiftlint:disable:next line_length
                    description: Text("Search returns bounded excerpts with path, locator, hash, freshness and evidence status.")
                )
        case .evidence:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(model.results.enumerated()), id: \.offset) { index, item in
                        resultCard(item, identifier: "S\(index + 1)")
                    }
                }
                .padding(16)
            }
        case .sources:
            sourceList
        case .claims:
            claimList
        case .timeline:
            timelineList
        case .revisions:
            revisionList
        case .reasoning:
            reasoningList
        }
    }

    private var reasoningList: some View {
        let references = model.reasoningClaimReferences
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Picker("Relation", selection: $model.reasoningRelation) {
                    ForEach(ResearchVaultReasoningRelationKind.allCases, id: \.self) {
                        Text($0.localizedTitle).tag($0)
                    }
                }
                .frame(width: 150)
                Picker("Subject claim", selection: $model.reasoningSubject) {
                    Text("Subject claim").tag(Optional<ResearchVaultReasoningClaimReference>.none)
                    ForEach(references, id: \.reference) { item in
                        Text(item.title).tag(Optional(item.reference))
                    }
                }
                Picker("Object claim", selection: $model.reasoningObject) {
                    Text("Object claim").tag(Optional<ResearchVaultReasoningClaimReference>.none)
                    ForEach(references, id: \.reference) { item in
                        Text(item.title).tag(Optional(item.reference))
                    }
                }
                Button("Review relation…") {
                    showReasoningPromotionConfirmation = true
                }
                .disabled(
                    model.reasoningSubject == nil
                        || model.reasoningObject == nil
                        || model.reasoningSubject == model.reasoningObject
                )
                Spacer()
                if let generation = model.reasoningGeneration {
                    Text("Generation \(generation) · SHADOW")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .accessibilityElement(children: .contain)

            Divider()

            HStack(spacing: 8) {
                Button("All facts") { Task { await model.refreshReasoningFacts() } }
                Button("Why we believe this") { Task { await model.loadReasoningDetail(.why) } }
                    .disabled(model.selectedReasoningFactID == nil)
                Button("Impacted claims") { Task { await model.loadReasoningDetail(.impacted) } }
                    .disabled(model.selectedReasoningFactID == nil)
                Button("What changed") { Task { await model.loadReasoningDetail(.whatChanged) } }
                Button("Unresolved contradictions") {
                    Task { await model.loadReasoningDetail(.contradictions) }
                }
                Button("Retract relation…", role: .destructive) {
                    showReasoningRetractionConfirmation = true
                }
                .disabled(!model.canRetractSelectedReasoningRelation)
                Spacer()
                Text("ASSERTED ≠ DERIVED · MODEL OUTPUT IS NEVER A RULE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            HSplitView {
                Group {
                    if model.reasoningFacts.isEmpty {
                        ContentUnavailableView(
                            "Reasoning shadow not initialized",
                            systemImage: "point.3.connected.trianglepath.dotted"
                        )
                    } else {
                        List(model.reasoningFacts, id: \.id) { fact in
                            Button {
                                model.selectedReasoningFactID = fact.id
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(fact.asserted ? "ASSERTED" : "DERIVED")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(fact.asserted ? Color.blue : Color.purple)
                                        Text(fact.predicate).font(.callout.weight(.semibold))
                                        Spacer()
                                        if fact.id == model.selectedReasoningFactID {
                                            Image(systemName: "checkmark.circle.fill")
                                        }
                                    }
                                    Text(fact.arguments.joined(separator: " → "))
                                        .font(.caption.monospaced())
                                        .lineLimit(2)
                                    Text("\(fact.receiptIDs.count) receipts · \(fact.sourceIDs.count) sources")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                "\(fact.asserted ? "Asserted" : "Derived") \(fact.predicate)"
                            )
                            .accessibilityHint("Select this fact to inspect proof or impact")
                        }
                    }
                }
                .frame(minWidth: 340)

                reasoningDetailView
                    .frame(minWidth: 420)
            }
        }
    }

    @ViewBuilder
    private var reasoningDetailView: some View {
        if let detail = model.reasoningDetail {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(detail.kind.rawValue).font(.headline)
                        Spacer()
                        if detail.truncated {
                            Text("TRUNCATED")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.orange)
                        }
                    }
                    if !detail.addedFactIDs.isEmpty {
                        reasoningIDGroup("Added", values: detail.addedFactIDs)
                    }
                    if !detail.removedFactIDs.isEmpty {
                        reasoningIDGroup("Removed", values: detail.removedFactIDs)
                    }
                    if !detail.updatedFactIDs.isEmpty {
                        reasoningIDGroup("Updated", values: detail.updatedFactIDs)
                    }
                    ForEach(detail.facts, id: \.id) { fact in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(fact.asserted ? "Asserted fact" : "Derived fact"): \(fact.predicate)")
                                .font(.callout.weight(.semibold))
                            Text(fact.arguments.joined(separator: " → "))
                                .font(.caption.monospaced())
                            ForEach(fact.receiptIDs, id: \.self) { receiptID in
                                Text("Receipt \(receiptID)").font(.caption2.monospaced())
                            }
                            ForEach(fact.sourceIDs, id: \.self) { sourceID in
                                Text(reasoningSourceDescription(
                                    receiptIDs: fact.receiptIDs,
                                    sourceID: sourceID
                                ))
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                            }
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityElement(children: .combine)
                    }
                    ForEach(Array(detail.derivations.enumerated()), id: \.offset) { _, derivation in
                        Text(
                            "Rule \(derivation.ruleID): "
                                + derivation.premiseFactIDs.joined(separator: ", ")
                        )
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                    }
                }
                .padding(12)
            }
        } else {
            ContentUnavailableView(
                "Select a reasoning action",
                systemImage: "list.bullet.rectangle.portrait"
            )
        }
    }

    private func reasoningIDGroup(_ title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(values, id: \.self) { Text($0).font(.caption2.monospaced()) }
        }
        .textSelection(.enabled)
    }

    private func reasoningSourceDescription(receiptIDs: [String], sourceID: String) -> String {
        for receipt in scopedApprovedReceipts where receiptIDs.contains(receipt.receiptID) {
            if let source = receipt.sources.first(where: { $0.id == sourceID }) {
                return "Source \(sourceID) · \(source.locator) · SHA-256 \(source.sha256)"
            }
        }
        return "Source \(sourceID) · exact locator unavailable"
    }

    private var sourceList: some View {
        let rows = ResearchVaultWorkbenchProjection.sources(receipts: scopedApprovedReceipts)
        return Group {
            if rows.isEmpty {
                ContentUnavailableView("No approved sources", systemImage: "doc.badge.clock")
            } else {
                List(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.source.locator).font(.callout.weight(.semibold))
                            Spacer()
                            Text(row.sensitivity.rawValue.uppercased())
                                .font(.caption2.weight(.bold))
                        }
                        Text(
                            "\(row.projectKey) · \(row.source.kind.rawValue) · observed \(row.ageDays)d ago"
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        Text("SHA-256 \(row.source.sha256)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var claimList: some View {
        let rows = ResearchVaultWorkbenchProjection.claims(receipts: scopedApprovedReceipts)
        return Group {
            if rows.isEmpty {
                ContentUnavailableView("No reviewed claims", systemImage: "checkmark.message")
            } else {
                List(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.status.rawValue).font(.caption2.weight(.bold))
                            Text(row.projectKey).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(row.createdAt.formatted()).font(.caption2.monospacedDigit())
                        }
                        Text(row.claim).textSelection(.enabled)
                        Group {
                            if row.evidenceIDs.isEmpty {
                                Text("No evidence ID attached")
                            } else {
                                Text("Evidence: \(row.evidenceIDs.joined(separator: ", "))")
                            }
                        }
                        .font(.caption2.monospaced())
                        .foregroundStyle(
                            row.evidenceIDs.isEmpty ? Color.orange : Color.secondary
                        )
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var timelineList: some View {
        let receipts = scopedApprovedReceipts.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.receiptID < $1.receiptID
        }
        return Group {
            if receipts.isEmpty {
                ContentUnavailableView("No approved history", systemImage: "clock.arrow.circlepath")
            } else {
                List(receipts, id: \.receiptID) { receipt in
                    let sourceCount = receipt.sources.count
                    let claimCount = receipt.findings.count
                    let sensitivity = receipt.sensitivity.rawValue.uppercased()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(receipt.createdAt.formatted()).font(.caption.monospacedDigit())
                            Text(receipt.projectKey).font(.caption.weight(.semibold))
                            Spacer()
                            Text(String(receipt.contentHash.prefix(12)))
                                .font(.caption2.monospaced())
                        }
                        Text(receipt.question).textSelection(.enabled)
                        Text("\(sourceCount) sources · \(claimCount) claims · \(sensitivity)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var revisionList: some View {
        let revisions = ResearchVaultWorkbenchProjection.revisions(
            receipts: scopedApprovedReceipts
        )
        let audit = ResearchVaultWorkbenchProjection.taxonomyAudit(
            receipts: scopedApprovedReceipts
        )
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Taxonomy audit").font(.caption.weight(.semibold))
                Text("\(audit.projectKeys.count) projects")
                Text("\(audit.sourceKinds.count) source kinds")
                Text("\(audit.evidenceStatuses.count) evidence states")
                Spacer()
                Text("\(audit.orphanEvidenceReferences) orphan references")
                    .foregroundStyle(
                        audit.orphanEvidenceReferences == 0 ? Color.secondary : Color.red
                    )
            }
            .font(.caption.monospacedDigit())
            .padding(12)
            Divider()
            if revisions.isEmpty {
                ContentUnavailableView(
                    "No revised source detected",
                    systemImage: "doc.text.magnifyingglass"
                )
            } else {
                List(revisions) { revision in
                    let versionCount = revision.versions.count
                    let impactedClaimCount = revision.impactedClaims.count
                    VStack(alignment: .leading, spacing: 4) {
                        Text(revision.locator).font(.callout.weight(.semibold))
                        Text("\(versionCount) hashed versions · \(impactedClaimCount) impacted claims")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        ForEach(revision.impactedClaims) { claim in
                            Text("\(claim.status.rawValue): \(claim.claim)")
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var quarantineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Quarantine (\(model.pendingItems.count))")
                    .font(.caption.weight(.semibold))
                Text("REVIEW REQUIRED")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                Spacer()
                if model.pendingItems.count > 1 {
                    Button("Approve all") {
                        Task {
                            await model.review(
                                model.pendingItems.map(\.receiptID),
                                action: .approve
                            )
                        }
                    }
                    Button("Reject all", role: .destructive) {
                        showBulkRejectConfirmation = true
                    }
                }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.pendingItems, id: \.receiptID) { item in
                        quarantineRow(item)
                        if item.receiptID != model.pendingItems.last?.receiptID {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: 130)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .confirmationDialog(
            "Reject all quarantined receipts?",
            isPresented: $showBulkRejectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reject all", role: .destructive) {
                Task {
                    await model.review(
                        model.pendingItems.map(\.receiptID),
                        action: .reject
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rejected receipts are removed from the encrypted vault.")
        }
    }

    private func quarantineRow(_ item: ResearchVaultQuarantineItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.question)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.projectKey)
                    Text(item.sensitivity.uppercased())
                    Text(Date(timeIntervalSince1970: Double(item.createdAtMS) / 1_000).formatted())
                    Text("\(item.sourceCount) source(s)")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                if let locator = item.firstSourceLocator {
                    Text(locator)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Button("Approve") {
                Task { await model.review([item.receiptID], action: .approve) }
            }
            .buttonStyle(.borderless)
            Button("Reject", role: .destructive) {
                Task { await model.review([item.receiptID], action: .reject) }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func resultCard(_ item: ResearchVaultContextItem, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(identifier).font(.caption2.bold()).foregroundStyle(.tint)
                Text(item.citation.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(item.citation.evidenceStatus?.rawValue.uppercased() ?? "UNCLASSIFIED")
                    .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            if let heading = item.heading { Text(heading).font(.caption.weight(.medium)) }
            Text(item.excerpt).font(.system(size: 12)).textSelection(.enabled)
            Text("\(item.citation.libraryPath) · \(item.citation.locator)")
                .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Text("SHA-256 \(item.citation.excerptSHA256) · observed \(item.citation.observedAt.formatted())")
                .font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

private extension ResearchVaultReasoningRelationKind {
    var localizedTitle: String {
        switch self {
        case .contradicts:
            String(localized: "Contradicts")
        case .supersedes:
            String(localized: "Supersedes")
        case .dependsOn:
            String(localized: "Depends on")
        }
    }
}
