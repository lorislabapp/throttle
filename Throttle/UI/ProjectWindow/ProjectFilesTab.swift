import AppKit
import SwiftUI

/// Read-only view of a project's Claude Code config files. v2.0 surfaces:
/// CLAUDE.md, .claude/settings.json, .claude/settings.local.json. Each row
/// shows a path, size, last-modified, and a "Reveal in Finder" / "Open"
/// button. Edits live in the (Pro) Optimizer tab — this is a viewer.
struct ProjectFilesTab: View {
    let project: ProjectInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                row(title: "CLAUDE.md",
                    url: project.claudeMdURL,
                    description: "Project memory loaded into every session.")
                row(title: ".claude/settings.json",
                    url: project.settingsJSONURL,
                    description: "Committed Claude Code config — hooks, model preferences, MCP servers.")
                row(title: ".claude/settings.local.json",
                    url: project.settingsLocalJSONURL,
                    description: "Per-machine override — gitignored, not shared with the team.")
                Divider().padding(.vertical, 4)
                projectRoot
            }
            .padding(20)
        }
    }

    private func row(title: String, url: URL?, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: url != nil ? "doc.text" : "doc.text.below.ecg")
                .font(.title3)
                .foregroundStyle(url != nil ? Color.accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                Text(description).font(.caption2).foregroundStyle(.tertiary)
                if let url {
                    HStack(spacing: 12) {
                        Text(formattedSize(url))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Text(modifiedAgo(url))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Not present")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if let url {
                HStack(spacing: 6) {
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    Button("Open") {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var projectRoot: some View {
        if let url = project.url {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Project root").font(.callout.weight(.semibold))
                    Text(url.path).font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(12)
        }
    }

    private func formattedSize(_ url: URL) -> String {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return "—"
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }

    private func modifiedAgo(_ url: URL) -> String {
        guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return "—"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
