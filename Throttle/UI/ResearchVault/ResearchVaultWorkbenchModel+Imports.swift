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
            try await client.admitProjects([projectKey])
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
        } catch ResearchDocumentTextExtractorError.ocrUnavailable(let file, let page) {
            status = String(
                localized:
                    "Local OCR is unavailable for page \(page) of \(file). The document was not imported.")
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
        guard !isIsolatedHost else { return }
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

                localized:
                    """
                    Inbox synced: \(response.insertedReceipts) imported, \
                    \(response.alreadyPresentReceipts) already present.
                    """
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

        panel.message = String(
            localized:
                "Throttle reads supported documents locally. It never signs in to Google or uploads this folder."
        )
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
            try await client.admitProjects([projectKey])
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

                localized:
                    """
                    NotebookLM migration: \(inserted) imported, \(present) already present · \
                    manifest \(batch.manifest.aggregateSHA256.prefix(12)).
                    """
            )
        } catch NotebookLMMigrationError.invalidProjectKey {
            status = String(localized: "Project key must use lowercase letters, numbers, dots, dashes or underscores.")
        } catch NotebookLMMigrationError.emptyExport {
            status = String(localized: "No supported NotebookLM export document was found.")
        } catch ResearchDocumentTextExtractorError.ocrUnavailable(let file, let page) {
            migrationManifest = nil
            status = String(
                localized:
                    "Local OCR is unavailable for page \(page) of \(file). The document was not imported.")
        } catch {
            migrationManifest = nil
            status = String(localized: "Migration failed closed. No source file was moved, deleted or uploaded.")
        }
    }

}
