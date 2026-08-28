import AppKit
import Observation
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
    var serviceState = ResearchVaultServiceManager.state
    var health: ResearchVaultHealthResponse?
    var status = String(localized: "Research Vault is disabled.")
    var isBusy = false
    var inboxFolderName = ResearchVaultInboxBookmarkStore.configuredFolderName
    var migrationProjectKey = "notebooklm-import"
    var migrationManifest: NotebookLMMigrationManifest?

    private let client: ResearchVaultClient?

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
            status = String(localized: "macOS could not change the Research Vault service.")
        }
    }

    func checkHealth() async {
        guard let client else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            health = try await client.health()
            status = String(localized: "Encrypted vault ready.")
        } catch {
            health = nil
            status = String(localized: "The signed Research Vault service is not reachable.")
        }
    }

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let client else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let bundle = try await client.search(query: trimmed)
            contextBundle = bundle
            results = bundle.items
            synthesis = nil
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
            status = String(localized: "Imported \(response.insertedReceipts); already present \(response.alreadyPresentReceipts).")
            await checkHealth()
        } catch {
            status = String(localized: "Import rejected. Files must be valid sealed receipts within the endpoint grant.")
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
            status = String(localized: "Inbox synced: \(response.insertedReceipts) imported, \(response.alreadyPresentReceipts) already present.")
            await checkHealth()
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
            status = String(localized: "NotebookLM migration: \(inserted) imported, \(present) already present · manifest \(batch.manifest.aggregateSHA256.prefix(12)).")
        } catch NotebookLMMigrationError.invalidProjectKey {
            status = String(localized: "Project key must use lowercase letters, numbers, dots, dashes or underscores.")
        } catch NotebookLMMigrationError.emptyExport {
            status = String(localized: "No supported NotebookLM export document was found.")
        } catch {
            migrationManifest = nil
            status = String(localized: "Migration failed closed. No source file was moved, deleted or uploaded.")
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
}

struct ResearchVaultWorkbenchView: View {
    let onBack: () -> Void
    @State private var model: ResearchVaultWorkbenchModel

    init(initialQuery: String = "", onBack: @escaping () -> Void) {
        self.onBack = onBack
        _model = State(initialValue: ResearchVaultWorkbenchModel(initialQuery: initialQuery))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onBack) { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                Text("Research Vault").font(.headline)
                Text("LOCAL · ENCRYPTED").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                serviceControl
            }
            .padding(16)

            Divider()

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Search evidence, decisions and prior research", text: $model.query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await model.search() } }
                    Button("Search") { Task { await model.search() } }
                        .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Synthesize on Mac") { Task { await model.synthesizeOnDevice() } }
                        .disabled(model.results.isEmpty)
                }
                HStack(spacing: 8) {
                    Button("Import receipts…") { Task { await model.importReceiptFiles() } }
                        .disabled(model.serviceState != .enabled)
                    Button(model.inboxFolderName.map { "Inbox: \($0)" } ?? "Choose Inbox…") {
                        model.chooseInboxFolder()
                    }
                    Button("Sync Inbox") { Task { await model.syncInbox() } }
                        .disabled(model.serviceState != .enabled || model.inboxFolderName == nil)
                    Spacer()
                }
                HStack(spacing: 8) {
                    TextField("notebooklm-import", text: $model.migrationProjectKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                        .help("Research Vault project key for migrated NotebookLM sources")
                    Button("Import NotebookLM export…") {
                        Task { await model.importNotebookLMExport() }
                    }
                    .disabled(model.serviceState != .enabled || model.migrationProjectKey.isEmpty)
                    if model.migrationManifest != nil {
                        Button("Save integrity manifest…") { model.saveMigrationManifest() }
                    }
                    Spacer()
                    Text("LOCAL MIGRATION · NO GOOGLE LOGIN")
                        .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
            }
            .padding(16)

            HStack {
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let health = model.health {
                    Text("\(health.documentCount) docs · \(health.receiptCount) receipts · SQLCipher \(health.cipherVersion)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 10)

            Divider()

            if let synthesis = model.synthesis {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ON-DEVICE DRAFT · NOT EVIDENCE")
                        .font(.caption2.weight(.bold)).foregroundStyle(.orange)
                    Text(synthesis.answer).font(.system(size: 12)).textSelection(.enabled)
                    Text("Citations: " + synthesis.citationIDs.joined(separator: ", "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let uncertainty = synthesis.uncertainty, !uncertainty.isEmpty {
                        Text("Uncertainty: " + uncertainty).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                Divider()
            }

            if model.results.isEmpty {
                ContentUnavailableView(
                    "Source-first local research",
                    systemImage: "lock.doc",
                    description: Text("Search returns bounded excerpts with path, locator, hash, freshness and evidence status.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(model.results.enumerated()), id: \.offset) { index, item in
                            resultCard(item, identifier: "S\(index + 1)")
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 860, height: 540)
        .task { if model.serviceState == .enabled { await model.checkHealth() } }
    }

    @ViewBuilder
    private var serviceControl: some View {
        switch model.serviceState {
        case .disabled:
            Button("Enable") { model.setEnabled(true) }
        case .enabled:
            Button("Disable") { model.setEnabled(false) }
        case .requiresApproval:
            Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
        case .unavailable:
            Text("Unavailable").foregroundStyle(.secondary)
        }
    }

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
