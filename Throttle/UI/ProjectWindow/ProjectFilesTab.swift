import AppKit
import SwiftUI

/// Read-only view of a project's Claude Code config files — cockpit style:
/// flat rows (doc · name/path · size/mod · Reveal/Open) divided by hairlines.
/// CLAUDE.md, .claude/settings.json, .claude/settings.local.json, plus the root.
struct ProjectFilesTab: View {
    let project: ProjectInfo
    private let hair = Color.primary.opacity(0.09)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionLabel("Config files")
                fileRow("CLAUDE.md", project.claudeMdURL,
                        "Project memory loaded into every session.")
                rowDivider
                fileRow(".claude/settings.json", project.settingsJSONURL,
                        "Committed config — hooks, model prefs, MCP servers.")
                rowDivider
                fileRow(".claude/settings.local.json", project.settingsLocalJSONURL,
                        "Per-machine override — gitignored, not shared.")
                if let url = project.url {
                    sectionLabel("Project root")
                    rootRow(url)
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 10.5, weight: .semibold)).tracking(0.8)
            .textCase(.uppercase).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 4)
    }

    private var rowDivider: some View {
        Rectangle().fill(hair).frame(height: 1).padding(.horizontal, 22)
    }

    private func fileRow(_ name: String, _ url: URL?, _ desc: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: "doc.text")
                .font(.system(size: 14)).foregroundStyle(url != nil ? Color.secondary : Color.primary.opacity(0.25))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 12.5).monospaced())
                Text(desc).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 10)
            if let url {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formattedSize(url)).font(.system(size: 11).monospaced()).foregroundStyle(.secondary)
                    Text(modifiedAgo(url)).font(.system(size: 10.5).monospaced()).foregroundStyle(.tertiary)
                }
                HStack(spacing: 10) {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        Text("Reveal").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.tint)
                    }.buttonStyle(.plain)
                    Button { NSWorkspace.shared.open(url) } label: {
                        Text("Open").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.tint)
                    }.buttonStyle(.plain)
                }
            } else {
                Text("not present").font(.system(size: 11).monospaced().italic()).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 11)
    }

    private func rootRow(_ url: URL) -> some View {
        HStack(spacing: 13) {
            Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 16)
            Text(url.path).font(.system(size: 11.5).monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 10)
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                Text("Reveal").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.tint)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 22).padding(.vertical, 11)
    }

    private func formattedSize(_ url: URL) -> String {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }

    private func modifiedAgo(_ url: URL) -> String {
        guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
