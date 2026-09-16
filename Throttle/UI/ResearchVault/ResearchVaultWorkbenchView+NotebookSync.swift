import AppKit
import SwiftUI

extension ResearchVaultWorkbenchView {
    /// Sync is per notebook and never implicit: a notebook is re-exported only
    /// while its own box is checked, into the folder it remembers, and what comes
    /// back is quarantined like any other import.
    @ViewBuilder
    var notebookSyncControls: some View {
        if !model.notebookLMNotebooks.isEmpty || !model.notebookSyncRecords.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keep in sync").font(.system(size: 13, weight: .semibold))
                    Text("Choose the notebooks Throttle re-exports when you ask. Nothing is automatic.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(Array(model.notebookLMNotebooks.enumerated()), id: \.element.id) { index, notebook in
                        if index > 0 { Divider() }
                        notebookSyncRow(notebook)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.10)))
                syncActionRow
            }
            .padding(.bottom, 12)
        }
    }

    private func notebookSyncRow(_ notebook: NotebookLMNotebookDescriptor) -> some View {
        let record = model.notebookSyncRecords.first { $0.notebookID == notebook.id }
        let isSyncing = model.syncingNotebookID == notebook.id
        return HStack(alignment: .center, spacing: 12) {
            Toggle(isOn: Binding(
                get: { record != nil },
                set: { model.setNotebookSync($0, notebookID: notebook.id, title: notebook.title) }
            )) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(model.isBusy)
                .accessibilityLabel(Text("Sync \(notebook.title)"))
            VStack(alignment: .leading, spacing: 3) {
                Text(notebook.title).font(.system(size: 13, weight: .medium))
                Text(Self.syncRowState(record, isSyncing: isSyncing, isWaiting: Self.isWaiting(record, model: model),
                                       progress: model.notebookLMImportProgress))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                if isSyncing, model.notebookLMImportProgress.total > 0 {
                    ProgressView(value: Double(model.notebookLMImportProgress.completed),
                                 total: Double(model.notebookLMImportProgress.total))
                        .frame(maxWidth: 260)
                        .accessibilityLabel(Text("Sync of \(notebook.title)"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.lastSyncLabel(record))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Last sync: \(Self.lastSyncLabel(record))"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 50)
    }

    /// The button says what it will do, and the sentence beside it says either
    /// exactly that or the one thing that stands in the way.
    private var syncActionRow: some View {
        let count = model.notebookSyncRecords.count
        let ready = model.notebookLMSyncEnabled && !model.isBusy && count > 0
        let syncing = model.syncingNotebookID != nil
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(syncing ? String(localized: "Syncing…") : String(localized: "Sync \(count) notebook(s)")) {
                Task { await model.syncEnabledNotebooks() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!ready)
            if syncing {
                Button("Stop") { Task { await model.stopNotebookSync() } }
                    .disabled(model.syncStopRequested)
            }
            Text(Self.syncSentence(
                exportAllowed: model.notebookLMSyncEnabled, syncing: syncing,
                stopping: model.syncStopRequested,
                titles: model.notebookSyncRecords.map(\.title)
            ))
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private static func isWaiting(_ record: ResearchVaultNotebookSyncRecord?,
                                  model: ResearchVaultWorkbenchModel) -> Bool {
        guard let record, let current = model.syncingNotebookID else { return false }
        return record.notebookID != current
    }

    static func syncRowState(_ record: ResearchVaultNotebookSyncRecord?, isSyncing: Bool, isWaiting: Bool,
                             progress: NotebookLMImportJob.Progress) -> String {
        if isSyncing {
            guard progress.total > 0 else { return String(localized: "In progress") }
            return String(localized: "In progress — \(importStanding(progress))")
        }
        if isWaiting { return String(localized: "Waiting") }
        return ResearchVaultStandingText.sync(record)
    }

    /// Only a run that happened has a date; a notebook never run says so, and an
    /// unselected one shows a dash rather than an invented value.
    static func lastSyncLabel(_ record: ResearchVaultNotebookSyncRecord?) -> String {
        guard let record else { return "—" }
        guard let last = record.lastSyncedAt else { return String(localized: "Never") }
        return last.formatted(date: .abbreviated, time: .shortened)
    }

    static func syncSentence(exportAllowed: Bool, syncing: Bool, stopping: Bool, titles: [String]) -> String {
        if syncing {
            return stopping
                ? String(localized: "Stopping after the current source. Nothing already received is lost.")
                : String(localized: "You can stop at any time; nothing already received is lost.")
        }
        guard exportAllowed else {
            return String(localized: "Unavailable: NotebookLM export is not allowed. Turn it on below.")
        }
        guard !titles.isEmpty else { return String(localized: "Select at least one notebook.") }
        let names = titles.formatted(.list(type: .and))
        return String(localized: "Will re-export \(names) to NotebookLM. What comes back is quarantined for review.")
    }
}
