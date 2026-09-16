import Foundation
import Observation

/// The projects the navigation lists: every folder Claude Code has worked in
/// that carries a Throttle plan, each read into the same overview the project
/// page shows. Loaded off the main actor and refreshed on demand, never on a
/// timer, because a plan read touches every task log.
@MainActor
@Observable
final class CockpitProjectsModel {
    static let shared = CockpitProjectsModel()

    struct Summary: Identifiable, Equatable {
        let path: String
        let name: String
        let overview: ProjectOverview
        var id: String { path }
        var blockedCount: Int { overview.progress.count(.blocked) + overview.progress.count(.failed) }
        var openDecisions: [ProjectOverview.Decision] { overview.decisions.filter(\.isOpen) }
    }

    private(set) var summaries: [Summary] = []
    private(set) var lastScan: Date?
    private(set) var isLoading = false

    /// Folders that have a Claude Code history but no plan yet, for "New plan…".
    private(set) var projectsWithoutPlan: [ProjectInfo] = []

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let loaded = await Task.detached(priority: .utility) { () -> ([Summary], [ProjectInfo]) in
            var summaries: [Summary] = []
            var without: [ProjectInfo] = []
            for project in ProjectsService.listProjects() where project.pathExists {
                guard let url = project.url else { continue }
                let store = PlanStore(projectRoot: url)
                guard store.planExists() else { without.append(project); continue }
                guard let resolved = try? store.resolveAll() else { continue }
                var events: [String: [TaskEvent]] = [:]
                for task in resolved.plan.tasks {
                    events[task.id] = (try? store.events(for: task.id).events) ?? []
                }
                let overview = ProjectOverview.project(plan: resolved.plan, states: resolved.states, events: events)
                summaries.append(Summary(path: url.path, name: project.displayName, overview: overview))
            }
            return (summaries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, without)
        }.value
        summaries = loaded.0
        projectsWithoutPlan = loaded.1
        lastScan = Date()
    }

    func summary(path: String) -> Summary? { summaries.first { $0.path == path } }
}
