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
        HStack {
            Button { onBack() } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            Spacer()
            Text("Project window").font(.headline)
            Spacer()
            Spacer().frame(width: 56)
        }
        .padding(.horizontal, 4).padding(.vertical, 4)
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
            tabBar
            Divider()
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

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { tab in
                let isActive = tab == selectedTab
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.localizedTitle)
                        .font(.callout.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? Color.primary : Color.secondary)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .background(
                            Rectangle()
                                .fill(isActive ? Color.accentColor.opacity(0.10) : .clear)
                        )
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(isActive ? Color.accentColor : .clear)
                                .frame(height: 2)
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .background(.regularMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 38))
                .foregroundStyle(.tertiary)
            Text("No project selected")
                .font(.headline)
            Text("Pick a project from the sidebar to see its stats, files, and optimizer suggestions.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func proLockPlaceholder(title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if !appState.isPro {
                Button {
                    if let url = URL(string: "https://buy.stripe.com/fZu14o7Hr0s0ant2nZds400") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Buy Throttle Pro · €19", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
            } else {
                Text("Pro feature — coming in a follow-up release.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
