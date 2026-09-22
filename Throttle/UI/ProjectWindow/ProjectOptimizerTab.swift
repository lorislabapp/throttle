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

    @State var selectedFile: EditableFile = .claudeMd
    @State var originalContents: String = ""
    @State var proposedContents: String = ""
    @State var status: String = ""
    @State var lastBackupURL: URL?
    @State var loading = true
    @State var rationale: [String] = []
    @State var optimizing = false
    @State var diffMode = false
    @State var optimizationTask: Task<Void, Never>?
    @State var revision = UUID()

    private let hair = Color.primary.opacity(0.09)

    enum EditableFile: String, CaseIterable, Identifiable {
        case claudeMd          = "CLAUDE.md"
        case settingsJSON      = ".claude/settings.json"
        case settingsLocalJSON = ".claude/settings.local.json"
        var id: String { rawValue }
        /// Short label for the segmented control (the full path is the value).
        var shortLabel: String {
            switch self {
            case .claudeMd:          return "CLAUDE.md"
            case .settingsJSON:      return "settings"
            case .settingsLocalJSON: return "settings.local"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(hair).frame(height: 1)
            Text("""
                Settings use local checks. AI instruction editing stays on this Mac and requires an \
                on-device model selected in Assistant.
                """)
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            TOONPotentialReadout()
            ReadFirewallReadout(project: project)
            EvalReadout(project: project)
            TraycerReadout(project: project)
            if loading {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if fileExists(for: selectedFile) || !proposedContents.isEmpty {
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
        .onDisappear { cancelOptimization() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $selectedFile) {
                ForEach(EditableFile.allCases) { f in Text(f.shortLabel).tag(f) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Picker("", selection: $diffMode) {
                Text("Split").tag(false)
                Text("Diff").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer(minLength: 12)
            if hasChanges {
                Text("Unsaved")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
            }
            if selectedFile != .claudeMd && !optimizing {
                borderedButton("Quick wins") { quickWins() }
            }
            if optimizing {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Optimising…").font(.system(size: 11)).foregroundStyle(.secondary) }
            } else if selectedFile == .claudeMd {
                Button { startOptimization() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles").font(.system(size: 11))
                        Text("Optimize on this Mac").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain).help("Propose a leaner, safer version + why it's better").fixedSize()
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
                .disabled(!isEditable || optimizing)
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
            if let backup = lastBackupURL, !optimizing {
                borderedButton("Rollback") { rollback(to: backup) }
            }
            borderedButton("Discard", disabled: !hasChanges || optimizing) {
                proposedContents = originalContents; status = ""
            }
            Button { Task { await apply() } } label: {
                Text("Apply").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 13).padding(.vertical, 6)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain).disabled(!hasChanges || optimizing).opacity(hasChanges ? 1 : 0.45)
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
            Text("\(selectedFile.rawValue) not present").font(.system(size: 14, weight: .semibold))
            Text("This project doesn't have \(selectedFile.rawValue) yet. Create a sensible starter — review the diff, fill in the placeholders, then Apply to create it.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            Button { startOptimization() } label: {
                HStack(spacing: 6) { Image(systemName: "doc.badge.plus"); Text("Create a starter") }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).padding(.top, 10)
            if !status.isEmpty {
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
    }

    private var hasChanges: Bool { proposedContents != originalContents }

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

}
