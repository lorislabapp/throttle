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
        guard !isIsolatedHost else { return }
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
