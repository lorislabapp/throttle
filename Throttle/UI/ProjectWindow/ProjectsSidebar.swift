import SwiftUI

/// Sidebar for the project window — cockpit style: a searchable list of Claude
/// Code projects, a RECENT section, flat rows (dot · name · recency), and an
/// "Include archived" footer toggle. See UI-SPEC-project-window.md.
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
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.tertiary)
                TextField("Search projects", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12.5))
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    Text(filtered.isEmpty ? "NO PROJECTS" : "RECENT")
                        .font(.system(size: 10, weight: .semibold)).tracking(0.7)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 5)
                    ForEach(filtered) { project in
                        row(project)
                    }
                }
                .padding(.horizontal, 8)
            }

            Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1)
            HStack(spacing: 9) {
                Text("Include archived").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Toggle("", isOn: $includeArchived)
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(.accentColor)
                    .help("Show projects with no activity in the last 30 days")
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .background(Color.primary.opacity(0.025))
    }

    private func row(_ project: ProjectInfo) -> some View {
        let sel = selection == project.id
        return HStack(spacing: 9) {
            Circle()
                .fill(sel ? Color.accentColor : Color.primary.opacity(project.pathExists ? 0.35 : 0.18))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.displayName).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(relativeDate(project.lastActive)).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7).fill(sel ? Color.primary.opacity(0.07) : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
                    sel ? Color.primary.opacity(0.11) : Color.clear, lineWidth: 1))
        )
        .contentShape(Rectangle())
        .onTapGesture { selection = project.id }
    }

    private func relativeDate(_ date: Date) -> String {
        guard date > .distantPast else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
