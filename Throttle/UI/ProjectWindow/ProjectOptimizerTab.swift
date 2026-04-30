import AppKit
import SwiftUI

/// Optimizer tab: edit-with-backup for CLAUDE.md, .claude/settings.json,
/// and .claude/settings.local.json. Two-pane layout — the original
/// (read-only) on the left, the proposed text on the right. Apply
/// commits via FileEditor, which backs up + atomic-writes + verifies.
///
/// The Assistant tab can hand off a proposal here via
/// `setProposed(file:contents:)`. v2.x → user types or pastes; future
/// version chains the AI's suggestions directly.
struct ProjectOptimizerTab: View {
    let project: ProjectInfo

    @State private var selectedFile: EditableFile = .claudeMd
    @State private var originalContents: String = ""
    @State private var proposedContents: String = ""
    @State private var status: String = ""
    @State private var lastBackupURL: URL?
    @State private var loading = true

    enum EditableFile: String, CaseIterable, Identifiable {
        case claudeMd          = "CLAUDE.md"
        case settingsJSON      = ".claude/settings.json"
        case settingsLocalJSON = ".claude/settings.local.json"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if loading {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let _ = url(for: selectedFile) {
                editorPanes
            } else {
                missingFile
            }
            Divider()
            actionBar
        }
        .onAppear { reload() }
        .onChange(of: project.id) { _, _ in reload() }
        .onChange(of: selectedFile) { _, _ in reload() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $selectedFile) {
                ForEach(EditableFile.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            Spacer()
            if hasChanges {
                Text("Unsaved")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var editorPanes: some View {
        HStack(spacing: 0) {
            paneSection(title: String(localized: "Current"),
                        body: originalContents,
                        isEditable: false,
                        binding: .constant(originalContents))
            Divider()
            paneSection(title: String(localized: "Proposed"),
                        body: proposedContents,
                        isEditable: true,
                        binding: $proposedContents)
        }
    }

    private func paneSection(
        title: String,
        body: String,
        isEditable: Bool,
        binding: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.bold())
                Spacer()
                Text("\(body.count) chars").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.top, 8)
            TextEditor(text: binding)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary)
                .disabled(!isEditable)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let backup = lastBackupURL {
                Button {
                    rollback(to: backup)
                } label: {
                    Label("Rollback", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            Button("Discard") {
                proposedContents = originalContents
                status = ""
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(!hasChanges)
            Button("Apply") {
                Task { await apply() }
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(!hasChanges)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var missingFile: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.below.ecg")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("File not present")
                .font(.headline)
            Text("\(selectedFile.rawValue) doesn't exist for this project yet. Create it on disk first, then come back to edit.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hasChanges: Bool { proposedContents != originalContents }

    // MARK: - Actions

    private func url(for file: EditableFile) -> URL? {
        switch file {
        case .claudeMd:          return project.claudeMdURL
        case .settingsJSON:      return project.settingsJSONURL
        case .settingsLocalJSON: return project.settingsLocalJSONURL
        }
    }

    private func reload() {
        loading = true
        status = ""
        guard let url = url(for: selectedFile) else {
            originalContents = ""
            proposedContents = ""
            loading = false
            return
        }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        originalContents = text
        proposedContents = text
        loading = false
    }

    private func apply() async {
        guard let url = url(for: selectedFile) else { return }
        do {
            let result = try await FileEditor.shared.write(url, contents: proposedContents)
            await MainActor.run {
                status = String(localized: "Saved at \(formatTime(result.timestamp)) · backup beside the file")
                lastBackupURL = result.backupURL
                originalContents = proposedContents
            }
        } catch {
            await MainActor.run {
                status = String(localized: "Save failed: \(error.localizedDescription)")
            }
        }
    }

    private func rollback(to backup: URL) {
        guard let url = url(for: selectedFile) else { return }
        Task {
            do {
                try await FileEditor.shared.rollback(backup, to: url)
                await MainActor.run {
                    status = String(localized: "Rolled back from \(backup.lastPathComponent)")
                    lastBackupURL = nil
                    reload()
                }
            } catch {
                await MainActor.run {
                    status = String(localized: "Rollback failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
