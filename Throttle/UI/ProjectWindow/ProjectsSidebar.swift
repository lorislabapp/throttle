import SwiftUI

/// Sidebar for the project window: searchable list of Claude Code projects,
/// sorted by recent activity. We don't virtualize because the dogfood scope
/// (Kevin's ~14 active projects) doesn't need it; SwiftUI's `List` handles
/// up to a few hundred rows fine without manual virtualization.
struct ProjectsSidebar: View {
    let projects: [ProjectInfo]
    @Binding var selection: String?
    @Binding var includeArchived: Bool
    @State private var search: String = ""

    private var filtered: [ProjectInfo] {
        guard !search.isEmpty else { return projects }
        let needle = search.lowercased()
        return projects.filter { $0.displayName.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            List(selection: $selection) {
                ForEach(filtered) { project in
                    row(for: project)
                        .tag(project.id)
                }
            }
            .listStyle(.sidebar)
            footer
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Search projects", text: $search)
                .textFieldStyle(.plain)
                .font(.callout)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial)
    }

    private func row(for project: ProjectInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: project.pathExists ? "folder" : "folder.badge.questionmark")
                .foregroundStyle(project.pathExists ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(relativeDate(project.lastActive))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(filtered.count) projects")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Toggle(isOn: $includeArchived) {
                Text("Archived").font(.caption2)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Show projects with no activity in the last 30 days")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial)
    }

    private func relativeDate(_ date: Date) -> String {
        guard date > .distantPast else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
