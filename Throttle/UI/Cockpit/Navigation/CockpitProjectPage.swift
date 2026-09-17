import SwiftUI

/// One project inside the Cockpit: its overview and its plan side by side as
/// two pages of the same place, instead of two windows with the same name.
struct CockpitProjectPage: View {
    @Environment(AppState.self) private var appState
    let cockpit: MultiCockpitModel
    let path: String

    enum Page: String, CaseIterable, Identifiable {
        case flow, overview, plan
        var id: String { rawValue }
        var title: String {
            switch self {
            case .flow: String(localized: "cockpit.view.flow", defaultValue: "Flow")
            case .overview: String(localized: "Overview")
            case .plan: String(localized: "cockpit.view.plan", defaultValue: "Plan")
            }
        }
    }

    @State private var page: Page = .flow
    /// The plan as a pipeline, re-read every few seconds while the Flow page is shown.
    @State private var flowOverview: ProjectOverview?
    @State private var flowLoaded = false
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
                .frame(width: 300)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            switch page {
            case .flow:
                flowPage
            case .overview:
                if let info = projectInfo {
                    ProjectOverviewTab(project: info, knownRoot: URL(fileURLWithPath: path, isDirectory: true))
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
                // Claude Code folds every character outside [A-Za-z0-9] into "-",
                // so "Éclair" can never be decoded back; encode the path instead.
                let encoded = Self.claudeProjectName(for: target)
                return ProjectsService.listProjects(includeArchived: true).first {
                    $0.encodedName == encoded || ProjectsService.decodePath($0.encodedName) == target
                }
            }.value
        }
        .task(id: "\(path)#\(page.rawValue)") {
            guard page == .flow else { return }
            let root = URL(fileURLWithPath: path, isDirectory: true)
            while !Task.isCancelled {
                flowOverview = await Task.detached(priority: .utility) {
                    CockpitProjectsModel.overview(at: root)
                }.value
                flowLoaded = true
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .onChange(of: cockpit.pendingPlanSelection) { _, selection in
            if selection != nil { page = .plan }
        }
        .onAppear {
            if cockpit.pendingPlanSelection != nil || cockpit.pendingProjectPlanPage { page = .plan }
            cockpit.pendingProjectPlanPage = false
        }
    }

    nonisolated static func claudeProjectName(for path: String) -> String {
        String(path.unicodeScalars.map { scalar in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        })
    }

    @ViewBuilder
    private var flowPage: some View {
        if let flowOverview {
            ProjectFlowView(cockpit: cockpit, overview: flowOverview,
                            projectRoot: URL(fileURLWithPath: path, isDirectory: true)) { taskID in
                cockpit.pendingPlanSelection = taskID
                page = .plan
            }
        } else if flowLoaded {
            ContentUnavailableView {
                Label("This project has no plan yet", systemImage: "list.bullet.rectangle")
            } description: {
                Text("Throttle proposes a starting plan from what is in the folder.")
            } actions: {
                Button("Create the plan") { page = .plan }.buttonStyle(.borderedProminent)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
