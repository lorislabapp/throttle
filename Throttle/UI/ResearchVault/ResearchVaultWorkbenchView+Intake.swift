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
    // MARK: - Add to vault

    var addToVaultSheet: some View {
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

    func sheetSectionHeader(_ title: LocalizedStringKey) -> some View {
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
    var everydayWays: some View {
        everydayRow(
            title: String(localized: "Connect a research library"),
            hint: String(
                localized: """
                One folder holding every project. Throttle reads each file’s project \
                from its path and creates the Spaces.
                """
            ),
            action: String(localized: "Connect…"),
            reason: nil
        ) {
            showAddToVault = false
            Task { await model.connectResearchLibrary() }
        }
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
    var occasionalWays: some View {
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

    var urlRow: some View {
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

    /// Sync is per notebook and never implicit: a notebook is re-exported only
    /// while its own switch is on, into the folder it remembers, and what comes
    /// back is quarantined like any other import.
    @ViewBuilder
    var notebookSyncControls: some View {
        if !model.notebookLMNotebooks.isEmpty || !model.notebookSyncRecords.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Keep in sync").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button("Sync now") { Task { await model.syncEnabledNotebooks() } }
                        .disabled(model.notebookSyncRecords.isEmpty || model.isBusy
                            || !model.notebookLMSyncEnabled)
                }
                ForEach(model.notebookLMNotebooks) { notebook in
                    let record = model.notebookSyncRecords.first { $0.notebookID == notebook.id }
                    Toggle(isOn: Binding(
                        get: { record != nil },
                        set: { model.setNotebookSync($0, notebookID: notebook.id, title: notebook.title) }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(notebook.title)
                            Text(Self.syncStanding(record))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .accessibilityHint(Text("Re-exports this notebook when you press Sync now."))
                }
            }
            .font(.system(size: 12))
            .padding(.bottom, 10)
        }
    }

    static func syncStanding(_ record: ResearchVaultNotebookSyncRecord?) -> String {
        guard let record else { return String(localized: "Not synced") }
        guard let last = record.lastSyncedAt else {
            return String(localized: "On — never run yet")
        }
        let when = last.formatted(date: .abbreviated, time: .shortened)
        guard let count = record.lastSourceCount else { return String(localized: "On — last run \(when)") }
        return String(localized: "On — \(count) source(s) at \(when)")
    }

    @ViewBuilder
    var notebookLMRow: some View {
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
                .accessibilityLabel(Text("NotebookLM import"))
                .accessibilityValue(Text(String(
                    localized: "\(model.notebookLMImportProgress.completed) of "
                        + "\(model.notebookLMImportProgress.total) sources"
                )))
            }
        }
        notebookSyncControls
        if model.migrationManifest != nil {
            Button("Save integrity manifest…") { model.saveMigrationManifest() }
                .padding(.bottom, 10)
        }
    }

    func everydayRow(
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

    func occasionalRow(
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
}
