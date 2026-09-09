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

    func loadNotebookLMNotebooks() async {
        guard !isIsolatedHost else { return }
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

    /// Turns this notebook's own sync on or off. Enabling remembers the staging
    /// folder the reader picks; disabling forgets it. Nothing syncs by itself.
    func setNotebookSync(_ enabled: Bool, notebookID: String, title: String) {
        guard !isIsolatedHost else { return }
        var folder: URL?
        if enabled {
            let panel = NSOpenPanel()
            panel.title = String(localized: "Choose the staging folder this notebook syncs into")
            panel.prompt = String(localized: "Enable Sync")
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            folder = chosen
        }
        do {
            let next = try ResearchVaultNotebookSyncStore.setting(
                enabled, notebookID: notebookID, title: title, folder: folder, in: notebookSyncRecords
            )
            try ResearchVaultNotebookSyncStore.save(next)
            notebookSyncRecords = next
            status = enabled
                ? String(localized: "Sync is on for this notebook. New sources still land in quarantine.")
                : String(localized: "Sync is off for this notebook and its folder is forgotten.")
        } catch {
            status = String(localized: "The sync setting could not be stored, so nothing changed.")
        }
    }

    /// Re-runs the export for every notebook whose own toggle is on, into the
    /// folder each one remembers. Idempotent by hash: a source that has not
    /// changed is counted as already present rather than imported twice.
    func syncEnabledNotebooks() async {
        guard !isIsolatedHost, notebookLMSyncEnabled, let client else {
            status = String(localized: "Enable explicit NotebookLM export for this session first.")
            return
        }
        guard !notebookSyncRecords.isEmpty else {
            status = String(localized: "No notebook has sync turned on.")
            return
        }
        isBusy = true
        defer { isBusy = false }
        var inserted = 0
        var present = 0
        var failed: [String] = []
        for record in notebookSyncRecords {
            do {
                let folder = try ResearchVaultNotebookSyncStore.stagingFolder(for: record)
                let accessed = folder.startAccessingSecurityScopedResource()
                defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
                let gateway = try NotebookLMGatewayClient()
                guard let notebook = try await gateway.listNotebooks()
                    .first(where: { $0.id == record.notebookID }) else {
                    failed.append(record.title)
                    continue
                }
                let progress = try await NotebookLMImportJob(gateway: gateway)
                    .run(notebook: notebook, stagingFolder: folder)
                guard progress.phase == .complete else { failed.append(record.title); continue }
                let counts = try await quarantineStagedImport(folder: folder, client: client)
                inserted += counts.inserted
                present += counts.present
                updateSyncRecord(record.notebookID, sourceCount: progress.total)
            } catch {
                failed.append(record.title)
            }
        }
        await checkHealth()
        let summary = String(
            localized: "Sync finished: \(inserted) new source(s) quarantined, \(present) already present."
        )
        status = failed.isEmpty
            ? summary
            : summary + " " + String(localized: "Unfinished: \(failed.joined(separator: ", ")).")
    }

    private func updateSyncRecord(_ notebookID: String, sourceCount: Int) {
        guard let index = notebookSyncRecords.firstIndex(where: { $0.notebookID == notebookID }) else { return }
        notebookSyncRecords[index].lastSyncedAt = Date()
        notebookSyncRecords[index].lastSourceCount = sourceCount
        try? ResearchVaultNotebookSyncStore.save(notebookSyncRecords)
    }

    func pauseNotebookLMImport() async {
        await activeNotebookLMImportJob?.requestPause()
        status = String(localized: "Pause requested; the current source will finish safely.")
    }

    func quarantineStagedImport(
        folder: URL,
        client: ResearchVaultClient
    ) async throws -> (inserted: Int, present: Int) {
        let batch = try NotebookLMMigrationImporter(
            root: folder,
            projectKey: migrationProjectKey,
            sensitivity: .internal
        ).load()
        try await client.admitProjects([migrationProjectKey])
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
            try await client.admitProjects([migrationProjectKey])
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
        guard !isIsolatedHost else { return }
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

    func loadApprovedReceipts(client: ResearchVaultClient) async throws -> [ResearchReceipt] {
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

    func chooseMarkdownExportFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a folder for the Markdown export")
        panel.prompt = String(localized: "Export")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    func writeMarkdown(
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
