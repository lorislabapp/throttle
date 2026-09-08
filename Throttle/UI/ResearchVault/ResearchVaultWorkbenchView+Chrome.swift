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

extension ResearchVaultWorkbenchView {
    // MARK: - Setup progress

    /// The three steps between a fresh install and a searchable vault. They are
    /// what the content area shows until every one of them is done, because a
    /// vault with nothing in it has nothing else worth saying.
    var vaultIsOn: Bool { model.serviceState == .enabled }
    var vaultWasRequested: Bool { vaultIsOn || model.serviceState == .requiresApproval }
    var loginItemsApproved: Bool { model.serviceState != .requiresApproval }

    var spaceFolders: [ResearchVaultFolderSource] {
        model.folderSources.filter {
            model.selectedSpace.kind == .portfolio || $0.spaceID == model.selectedSpaceID
        }
    }

    var hasASource: Bool {
        !spaceFolders.isEmpty || (model.health?.documentCount ?? 0) > 0
    }

    var setupComplete: Bool { vaultIsOn && loginItemsApproved && hasASource }

    // MARK: - Chrome

    var titleBar: some View {
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

    var searchBlock: some View {
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
    var secondaryActions: some View {
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
    func reasonedAction(
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

    var trustLine: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            }
            Text(model.status)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 11.5).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}
