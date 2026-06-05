import AppKit
import SwiftUI

/// Optimizer tab: edit-with-backup for CLAUDE.md, .claude/settings.json,
/// and .claude/settings.local.json. Two-pane layout — the original
/// (read-only) on the left, the proposed text on the right. Apply
/// commits via FileEditor, which backs up + atomic-writes + verifies.
///
/// Cockpit restyle keeps the real editor's function intact (the Design mock
/// showed a fictional "savings wizard" — not this; we styled the real thing).
struct ProjectOptimizerTab: View {
    let project: ProjectInfo

    @State private var selectedFile: EditableFile = .claudeMd
    @State private var originalContents: String = ""
    @State private var proposedContents: String = ""
    @State private var status: String = ""
    @State private var lastBackupURL: URL?
    @State private var loading = true

    private let hair = Color.primary.opacity(0.09)

    enum EditableFile: String, CaseIterable, Identifiable {
        case claudeMd          = "CLAUDE.md"
        case settingsJSON      = ".claude/settings.json"
        case settingsLocalJSON = ".claude/settings.local.json"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(hair).frame(height: 1)
            if loading {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if url(for: selectedFile) != nil {
                editorPanes
            } else {
                missingFile
            }
            Rectangle().fill(hair).frame(height: 1)
            actionBar
        }
        .onAppear { reload() }
        .onChange(of: project.id) { _, _ in reload() }
        .onChange(of: selectedFile) { _, _ in reload() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $selectedFile) {
                ForEach(EditableFile.allCases) { f in Text(f.rawValue).tag(f) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
            Spacer(minLength: 0)
            if hasChanges {
                Text("Unsaved changes")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var editorPanes: some View {
        HStack(spacing: 0) {
            paneSection(title: String(localized: "Current"),
                        body: originalContents, isEditable: false,
                        binding: .constant(originalContents))
            Rectangle().fill(hair).frame(width: 1)
            paneSection(title: String(localized: "Proposed"),
                        body: proposedContents, isEditable: true,
                        binding: $proposedContents)
        }
    }

    private func paneSection(title: String, body: String, isEditable: Bool,
                             binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 10.5, weight: .semibold)).tracking(0.8)
                    .textCase(.uppercase).foregroundStyle(.tertiary)
                Spacer()
                Text("\(body.count) chars").font(.system(size: 10.5).monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.top, 10)
            TextEditor(text: binding)
                .font(.system(size: 12).monospaced())
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Color.primary.opacity(0.03))
                .disabled(!isEditable)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            if !status.isEmpty {
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let backup = lastBackupURL {
                borderedButton("Rollback") { rollback(to: backup) }
            }
            borderedButton("Discard", disabled: !hasChanges) {
                proposedContents = originalContents; status = ""
            }
            Button { Task { await apply() } } label: {
                Text("Apply").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 13).padding(.vertical, 6)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain).disabled(!hasChanges).opacity(hasChanges ? 1 : 0.45)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private func borderedButton(_ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 11).padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
        .disabled(disabled).opacity(disabled ? 0.45 : 1)
    }

    private var missingFile: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.badge.plus").font(.system(size: 28)).foregroundStyle(.tertiary)
            Text("File not present").font(.system(size: 14, weight: .semibold))
            Text("\(selectedFile.rawValue) doesn't exist for this project yet. Create it on disk first, then come back to edit.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
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
