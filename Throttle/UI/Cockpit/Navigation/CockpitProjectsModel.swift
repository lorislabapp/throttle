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
        /// Nil while the project has no plan yet: it is listed because a session works in it.
        let overview: ProjectOverview?
        var id: String { path }
        var blockedCount: Int {
            guard let overview else { return 0 }
            return overview.progress.count(.blocked) + overview.progress.count(.failed)
        }
        var openDecisions: [ProjectOverview.Decision] { overview?.decisions.filter(\.isOpen) ?? [] }
    }

    private(set) var summaries: [Summary] = []
    private(set) var lastScan: Date?
    private(set) var isLoading = false
    /// Project root per session working directory, as resolved at the last refresh.
    private(set) var rootByWorkingDirectory: [String: String] = [:]

    /// Lists every project that has a plan, plus every project an open session
    /// works in (with or without a plan), so a session is never orphaned.
    func refresh(sessionDirectories: [String] = MultiCockpitModel.shared.sessions.map(\.cwd)) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let overrides = SessionProjectResolver.storedOverrides()
        let loaded = await Task.detached(priority: .utility) { () -> ([Summary], [String: String]) in
            var roots: [String: String] = [:]
            for cwd in Set(sessionDirectories) where !cwd.isEmpty {
                if let root = SessionProjectResolver.projectRoot(forWorkingDirectory: cwd, overrides: overrides) {
                    roots[cwd] = root
                }
            }
            // The listing does not probe the disk (pathExists is always false there and
            // hyphenated names decode wrongly), so resolve each folder here, off the main actor.
            var candidates = Set(roots.values)
            for project in ProjectsService.listProjects() {
                if let path = ProjectsService.decodePath(project.encodedName),
                   FileManager.default.fileExists(atPath: path),
                   PlanStore(projectRoot: URL(fileURLWithPath: path, isDirectory: true)).planExists() {
                    candidates.insert(path)
                }
            }
            let sessionRoots = Set(roots.values)
            var summaries: [Summary] = []
            for path in candidates {
                let url = URL(fileURLWithPath: path, isDirectory: true)
                summaries.append(Summary(path: path, name: url.lastPathComponent, overview: Self.overview(at: url)))
            }
            // A project without a plan and without a session is not worth a row.
            summaries.removeAll { $0.overview == nil && !sessionRoots.contains($0.path) }
            return (summaries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, roots)
        }.value
        summaries = loaded.0
        rootByWorkingDirectory = loaded.1
        lastScan = Date()
        publishWaiting(from: MultiCockpitModel.shared)
    }

    /// Hands Siri and Shortcuts the same "what waits on you" the Today page shows.
    func publishWaiting(from cockpit: MultiCockpitModel) {
        ThrottleWaitingSnapshotStore.write(ThrottleWaitingSnapshot.make(
            questions: cockpit.sessions.filter(\.needsInput).map { ($0.projectName, $0.latestQuestion) },
            projects: summaries.map {
                ThrottleWaitingProject(name: $0.name, decisions: $0.openDecisions.map(\.title),
                                       blocked: $0.blockedCount)
            }
        ))
    }

    nonisolated static func overview(at url: URL) -> ProjectOverview? {
        let store = PlanStore(projectRoot: url)
        guard store.planExists(), let resolved = try? store.resolveAll() else { return nil }
        var events: [String: [TaskEvent]] = [:]
        for task in resolved.plan.tasks {
            events[task.id] = (try? store.events(for: task.id).events) ?? []
        }
        return ProjectOverview.project(plan: resolved.plan, states: resolved.states, events: events)
    }

    /// Sessions whose folder resolves to this project.
    func sessions(in path: String, from cockpit: MultiCockpitModel) -> [CockpitTab] {
        cockpit.sessions.filter { rootByWorkingDirectory[$0.cwd] == path }
    }

    func summary(path: String) -> Summary? { summaries.first { $0.path == path } }
}
