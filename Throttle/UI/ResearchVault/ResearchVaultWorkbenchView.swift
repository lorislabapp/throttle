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

struct ResearchVaultWorkbenchView: View {
    let onBack: () -> Void
    @State var model: ResearchVaultWorkbenchModel
    @State var showBulkRejectConfirmation = false
    @State var showReasoningPromotionConfirmation = false
    @State var showReasoningRetractionConfirmation = false
    @State var pane = WorkbenchPane.evidence
    @State var showAddToVault = false

    enum WorkbenchPane: String, CaseIterable, Identifiable {
        case evidence = "Evidence"
        case sources = "Sources"
        case claims = "Claims"
        case timeline = "Timeline"
        case revisions = "Revisions"
        case reasoning = "Reasoning"

        var id: String { rawValue }

        /// Command-1 to Command-6, in the order the sidebar lists them, so the
        /// whole window is reachable without a pointer.
        var shortcut: KeyEquivalent {
            switch self {
            case .evidence: "1"
            case .sources: "2"
            case .claims: "3"
            case .timeline: "4"
            case .revisions: "5"
            case .reasoning: "6"
            }
        }

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
        self.init(model: ResearchVaultWorkbenchModel(initialQuery: initialQuery), onBack: onBack)
    }

    init(model: ResearchVaultWorkbenchModel, onBack: @escaping () -> Void) {
        self.onBack = onBack
        _model = State(initialValue: model)
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
        .onReceive(NotificationCenter.default.publisher(for: .throttleResearchVaultConnectLibrary)) { _ in
            Task { await model.connectResearchLibrary() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshAfterActivation() }
        }
        .task { if !model.isIsolatedHost, model.serviceState == .enabled { await model.checkHealth() } }
        .task {
            guard !model.isIsolatedHost else { return }
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
}
