import SwiftUI

/// SwiftUI root for the project window. Two-pane layout:
/// sidebar (projects list) + tabbed detail view.
///
/// Pro-paywalled: Free users see the window but tabs surface upgrade CTAs.
/// Trial-active users get the same experience as Pro.
struct ProjectWindowRoot: View {
    @Environment(AppState.self) private var appState
    let onBack: () -> Void
    @State private var projects: [ProjectInfo] = []
    @State private var selectedProjectID: String?
    @State private var selectedTab: Tab = .stats
    @State private var includeArchived: Bool = false

    enum Tab: String, CaseIterable, Identifiable {
        case stats     = "Stats"
        case files     = "Files"
        case optimizer = "Optimizer"
        case assistant = "Assistant"
        var id: String { rawValue }

        var localizedTitle: String {
            switch self {
            case .stats:     return String(localized: "Stats")
            case .files:     return String(localized: "Files")
            case .optimizer: return String(localized: "Optimizer")
            case .assistant: return String(localized: "Assistant")
            }
        }

        /// Tabs Free users can read but not act on. The window itself is
        /// Pro-only at v2.0; this map will become useful when we extend
        /// the trial experience to non-Pro users.
        var requiresPro: Bool {
            switch self {
            case .stats, .files: return false
            case .optimizer, .assistant: return true
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                ProjectsSidebar(
                    projects: projects,
                    selection: $selectedProjectID,
                    includeArchived: $includeArchived
                )
                .frame(width: 220)
                Divider()
                if let project = selectedProject {
                    detailContent(for: project)
                } else {
                    emptyState
                }
            }
        }
        .onAppear { reloadProjects() }
        .onChange(of: includeArchived) { _, _ in reloadProjects() }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Button { onBack() } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 14)).foregroundStyle(.primary.opacity(0.85))
            Text("Throttle").font(.system(size: 13, weight: .medium))
            if appState.isPro {
                Text("PRO").font(.system(size: 9, weight: .heavy))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(.secondary)
            } else {
                Text("FREE").font(.system(size: 9, weight: .heavy))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .foregroundStyle(.tertiary)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var selectedProject: ProjectInfo? {
        guard let id = selectedProjectID else { return nil }
        return projects.first { $0.id == id }
    }

    private func reloadProjects() {
        let list = ProjectsService.listProjects(includeArchived: includeArchived)
        self.projects = list
        if let id = selectedProjectID, !list.contains(where: { $0.id == id }) {
            self.selectedProjectID = list.first?.id
        } else if selectedProjectID == nil {
            self.selectedProjectID = list.first?.id
        }
    }

    @ViewBuilder
    private func detailContent(for project: ProjectInfo) -> some View {
        VStack(spacing: 0) {
            detailHeader(project)
            tabBar
            Group {
                switch selectedTab {
                case .stats:
                    ProjectStatsTab(project: project)
                case .files:
                    ProjectFilesTab(project: project)
                case .optimizer:
                    if appState.isPro {
                        ProjectOptimizerTab(project: project)
                    } else {
                        proLockPlaceholder(title: String(localized: "Optimizer"),
                                            message: String(localized: "Edit CLAUDE.md, settings.json, and hooks with backup, diff preview, and one-click rollback. Pro feature."))
                    }
                case .assistant:
                    if appState.isPro {
                        ProjectAssistantTab(project: project)
                    } else {
                        proLockPlaceholder(title: String(localized: "Assistant"),
                                            message: String(localized: "AI assistant trained on your project's config — Apple Intelligence (local), Claude via your subscription, or BYO API key. Pro feature."))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(_ project: ProjectInfo) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(project.displayName).font(.system(size: 19, weight: .semibold)).tracking(-0.3)
                if let path = project.projectPath {
                    Text(path).font(.system(size: 11.5).monospaced()).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if let path = project.projectPath {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Text("Reveal in Finder").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 14)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { tab in
                let on = tab == selectedTab
                Button { selectedTab = tab } label: {
                    HStack(spacing: 4) {
                        Text(tab.localizedTitle).font(.system(size: 12.5, weight: on ? .semibold : .medium))
                        if tab.requiresPro && !appState.isPro {
                            Image(systemName: "lock.fill").font(.system(size: 9)).opacity(0.6)
                        }
                    }
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .overlay(alignment: .bottom) {
                        if on {
                            RoundedRectangle(cornerRadius: 2).fill(Color.accentColor)
                                .frame(height: 2).padding(.horizontal, 12)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1) }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("Select a project").font(.system(size: 14.5, weight: .semibold))
            Text("Pick a project from the sidebar to see its usage, files and tools.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func proLockPlaceholder(title: String, message: String) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "lock.fill")
                .font(.system(size: 26)).foregroundStyle(.tertiary).padding(.bottom, 11)
            Text("\(title) is a Pro feature").font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340).padding(.top, 5)
            HStack(spacing: 22) {
                Label("Optimizer", systemImage: "bolt").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Label("Project assistant", systemImage: "bubble.left").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .padding(.top, 16)
            if !appState.isPro {
                Button {
                    if let url = URL(string: "https://lorislab.fr/throttle/buy") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("Upgrade to Pro · €29")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
            } else {
                Text("Coming in a follow-up release.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(26)
    }
}
