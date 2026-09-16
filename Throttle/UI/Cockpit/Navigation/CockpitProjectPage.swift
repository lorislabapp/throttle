import SwiftUI

/// One project inside the Cockpit: its overview and its plan side by side as
/// two pages of the same place, instead of two windows with the same name.
struct CockpitProjectPage: View {
    @Environment(AppState.self) private var appState
    let cockpit: MultiCockpitModel
    let path: String

    enum Page: String, CaseIterable, Identifiable {
        case overview, plan
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: String(localized: "Overview")
            case .plan: String(localized: "cockpit.view.plan", defaultValue: "Plan")
            }
        }
    }

    @State private var page: Page = .overview
    /// Read once per project: listing projects scans ~/.claude/projects.
    @State private var projectInfo: ProjectInfo?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: URL(fileURLWithPath: path).lastPathComponent)
                        .font(.system(size: 17, weight: .semibold))
                    Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                Picker(selection: $page) {
                    ForEach(Page.allCases) { Text(verbatim: $0.title).tag($0) }
                } label: { EmptyView() }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            switch page {
            case .overview:
                if let info = projectInfo {
                    ProjectOverviewTab(project: info)
                } else {
                    ContentUnavailableView("This folder has no Claude Code history yet",
                                           systemImage: "folder.badge.questionmark")
                }
            case .plan:
                CockpitPlanView(cockpit: cockpit, fixedProjectRoot: URL(fileURLWithPath: path, isDirectory: true))
            }
        }
        .task(id: path) {
            let target = path
            projectInfo = await Task.detached(priority: .userInitiated) {
                ProjectsService.listProjects(includeArchived: true).first { $0.projectPath == target }
            }.value
        }
        .onChange(of: cockpit.pendingPlanSelection) { _, selection in
            if selection != nil { page = .plan }
        }
    }
}
