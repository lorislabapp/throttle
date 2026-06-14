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
    @State private var rationale: [String] = []
    @State private var optimizing = false
    @State private var diffMode = false

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
                if diffMode { diffPane } else { editorPanes }
            } else {
                missingFile
            }
            if !rationale.isEmpty {
                Rectangle().fill(hair).frame(height: 1)
                whyPanel
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
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
            Picker("", selection: $diffMode) {
                Text("Split").tag(false)
                Text("Diff").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 110)
            Spacer(minLength: 8)
            if optimizing {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Optimising…").font(.system(size: 11)).foregroundStyle(.secondary) }
            } else {
                Button { Task { await optimizeWithAI() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles").font(.system(size: 11))
                        Text("Optimize with AI").font(.system(size: 12, weight: .medium))
                    }.foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain).help("Propose a leaner, safer version + why it's better")
            }
            if hasChanges {
                Text("Unsaved changes")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange).padding(.leading, 4)
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

    private var diffPane: some View {
        let lines = LineDiff.compute(originalContents, proposedContents)
        let c = LineDiff.counts(lines)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("CHANGES").font(.system(size: 10.5, weight: .semibold)).tracking(0.8).foregroundStyle(.tertiary)
                if c.added > 0 { Text("+\(c.added)").font(.system(size: 11, weight: .semibold).monospaced()).foregroundStyle(.green) }
                if c.removed > 0 { Text("−\(c.removed)").font(.system(size: 11, weight: .semibold).monospaced()).foregroundStyle(.red) }
                if c.added == 0 && c.removed == 0 { Text("no changes").font(.system(size: 11)).foregroundStyle(.tertiary) }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
            DiffView(lines: lines)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        rationale = []
        loading = false
    }

    /// Ask the active AI provider to propose a leaner/safer version + why.
    private func optimizeWithAI() async {
        optimizing = true; status = ""; rationale = []
        do {
            let p = try await AIOptimizerService.optimize(
                fileLabel: selectedFile.rawValue, content: originalContents,
                projectName: project.displayName, projectPath: project.projectPath)
            await MainActor.run {
                proposedContents = p.proposed
                rationale = p.why
                diffMode = p.changed   // show the diff when there's something to see
                if !p.changed { status = String(localized: "Already optimal — no changes proposed.") }
                optimizing = false
            }
        } catch {
            await MainActor.run {
                status = String(localized: "Optimize failed: \(error.localizedDescription)")
                optimizing = false
            }
        }
    }

    private var whyPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(Color.accentColor)
                Text("WHY THIS IS BETTER").font(.system(size: 9.5, weight: .semibold)).tracking(0.8).foregroundStyle(.tertiary)
            }
            ForEach(rationale, id: \.self) { r in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(r).font(.system(size: 11.5)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.05))
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
