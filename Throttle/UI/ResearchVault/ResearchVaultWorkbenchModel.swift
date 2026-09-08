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

@MainActor
@Observable
final class ResearchVaultWorkbenchModel {
    var query = ""
    var results: [ResearchVaultContextItem] = []
    var contextBundle: ResearchVaultContextBundle?
    var synthesis: ResearchVaultSynthesisDraft?
    var serviceState = ResearchVaultServiceManager.State.disabled
    var health: ResearchVaultHealthResponse?
    var status = String(localized: "Research Vault is disabled.")
    var isBusy = false
    var inboxFolderName: String?
    var migrationProjectKey = "notebooklm-import"
    var migrationManifest: NotebookLMMigrationManifest?
    var urlToImport = ""
    var pendingItems: [ResearchVaultQuarantineItem] = []
    var notebookLMNotebooks: [NotebookLMNotebookDescriptor] = []
    var selectedNotebookID: String?
    var notebookLMImportProgress = NotebookLMImportJob.Progress.idle
    var notebookLMSyncEnabled = false
    var approvedReceipts: [ResearchReceipt] = []
    var savedViews: [ResearchVaultSavedView] = []
    var selectedSavedViewID: UUID?
    var reasoningFacts: [ResearchVaultReasoningFactDTO] = []
    var reasoningDetail: ResearchVaultReasoningQueryResponse?
    var reasoningGeneration: Int64?
    var selectedReasoningFactID: String?
    var reasoningRelation = ResearchVaultReasoningRelationKind.dependsOn
    var reasoningSubject: ResearchVaultReasoningClaimReference?
    var reasoningObject: ResearchVaultReasoningClaimReference?
    var spaces: [ResearchVaultSpace] = [.portfolio] + ["cheatcode", "throttle"].map {
        ResearchVaultSpace(id: "project:" + $0, name: $0, kind: .project, projectKeys: [$0])
    }
    var selectedSpaceID = "project:throttle"
    var folderSources: [ResearchVaultFolderSource] = []
    /// A query that returned nothing and a vault nobody has searched yet look
    /// identical in the results area, and they need opposite words.
    var hasSearched = false
    var lastQuery = ""

    /// Test windows render layout only; they never connect to the installed vault.
    let isIsolatedHost = AppDelegate.isIsolatedHost
    let client: ResearchVaultClient?
    var activeNotebookLMImportJob: NotebookLMImportJob?
    var folderMonitor: ResearchVaultFolderMonitor?

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
        guard !isIsolatedHost else {
            client = nil
            return
        }
        inboxFolderName = ResearchVaultInboxBookmarkStore.configuredFolderName
        savedViews = ResearchVaultSavedViewStore.load()
        spaces = ResearchVaultSpaceStore.load(projectKeys: ["cheatcode", "throttle"])
        folderSources = ResearchVaultFolderSourceStore.load()
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
        guard !isIsolatedHost else { return }
        serviceState = ResearchVaultServiceManager.state
        switch serviceState {
        case .unavailable: status = String(localized: "Research Vault is unavailable in this build.")
        case .disabled: status = String(localized: "Research Vault is disabled.")
        case .requiresApproval:
            status = String(localized: "Allow Research Vault in System Settings > Login Items.")
        case .enabled: status = String(localized: "Research Vault is enabled.")
        }
    }

    /// Login Items approval happens outside this window. Reconcile it when
    /// the user returns, including the first health read after activation.
    func refreshAfterActivation() async {
        guard !isIsolatedHost else { return }
        let previous = serviceState
        refreshState()
        if serviceState == .enabled, previous != .enabled {
            await checkHealth()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard !isIsolatedHost else { return }
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

    func refreshSpaces() {
        guard !isIsolatedHost else { return }
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
        guard !isIsolatedHost else { return }
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
