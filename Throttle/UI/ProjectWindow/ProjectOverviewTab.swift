import GRDB
import SwiftUI

/// The project's "Overview" tab: objective and verified progress on the left;
/// decisions, changes, evidence and costs on the right. Any task, decision,
/// change or proof opens an inspector in place — no node becomes its own screen.
///
/// Read-only. It reads the plan, its logs and the budget ledger from the
/// project's `.throttle/` folder and never writes to them.
struct ProjectOverviewTab: View {
    @Environment(AppState.self) var appState
    let project: ProjectInfo

    @State var overview: ProjectOverview?
    @State var costs: ProjectCostReadout?
    @State var loadError: String?
    @State var loading = true
    /// Id of the node whose inspector is open: a task, decision, change or proof.
    @State var inspected: String?
    /// The decision whose "Settle" sheet is open.
    @State var settling: ProjectOverview.Decision?
    /// The project folder as it really is on disk, resolved once per load.
    @State var resolvedRoot: URL?

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView("The plan could not be read", systemImage: "exclamationmark.triangle",
                                       description: Text(verbatim: loadError))
            } else if let overview {
                ScrollView { columns(overview).padding(20) }
            } else {
                ContentUnavailableView(
                    "No plan for this project",
                    systemImage: "list.bullet.rectangle",
                    description: Text("The overview appears once the project has a plan in .throttle/plan.json.")
                )
            }
        }
        .task(id: project.id) { await reload() }
        .sheet(item: $settling) { decision in
            if let root = resolvedRoot ?? project.url {
                SettleDecisionSheet(decision: decision, projectRoot: root) {
                    settling = nil
                    Task { await reload() }
                }
            }
        }
    }

    private func columns(_ overview: ProjectOverview) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                leftColumn(overview).frame(minWidth: 320, maxWidth: .infinity)
                rightColumn(overview).frame(minWidth: 320, maxWidth: .infinity)
            }
            VStack(spacing: 14) {
                leftColumn(overview)
                rightColumn(overview)
            }
        }
    }

    private func leftColumn(_ overview: ProjectOverview) -> some View {
        VStack(spacing: 14) {
            objectiveCard(overview)
            progressCard(overview)
        }
    }

    private func rightColumn(_ overview: ProjectOverview) -> some View {
        VStack(spacing: 14) {
            decisionsCard(overview.decisions)
            changesCard(overview.changes)
            evidenceCard(overview.evidence)
            if let costs { costsCard(costs) }
        }
    }

    // MARK: Loading

    func reload() async {
        loading = true
        defer { loading = false }
        let encoded = project.encodedName
        // ProjectInfo.url is the fast, lossy decode: a hyphenated folder name
        // (Lumen-for-Frigate) would point at a path that does not exist.
        let naive = project.url
        guard let root = await Task.detached(operation: {
            ProjectsService.decodePath(encoded).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? naive
        }).value else {
            overview = nil
            return
        }
        resolvedRoot = root
        let database = appState.database
        let loaded = await Task.detached { () -> Result<Loaded, Error> in
            do {
                let store = PlanStore(projectRoot: root)
                var overview: ProjectOverview?
                if store.planExists() {
                    let resolved = try store.resolveAll()
                    var events: [String: [TaskEvent]] = [:]
                    for task in resolved.plan.tasks {
                        events[task.id] = (try? store.events(for: task.id).events) ?? []
                    }
                    overview = ProjectOverview.project(plan: resolved.plan, states: resolved.states, events: events)
                }
                let estimate = try? database.read { reader in
                    try StatsDataService.costForProject(in: reader, encodedName: encoded,
                                                        fromHoursAgo: 0, toHoursAgo: 720)
                }
                let storage = BudgetAdmissionStorage(projectRoot: root)
                let ledger = storage.ledgerExists ? try? storage.load() : nil
                return .success(Loaded(overview: overview, monthEstimateEUR: estimate, ledger: ledger))
            } catch {
                return .failure(error)
            }
        }.value
        switch loaded {
        case .success(let result):
            overview = result.overview
            costs = ProjectCostReadout.make(monthEstimateEUR: result.monthEstimateEUR, ledger: result.ledger,
                                            format: Self.euros)
            loadError = nil
        case .failure(let error):
            overview = nil
            loadError = String(describing: error)
        }
    }

    private struct Loaded: Sendable {
        let overview: ProjectOverview?
        let monthEstimateEUR: Double?
        let ledger: BudgetAdmissionLedger?
    }

    static func euros(_ value: Double) -> String {
        value.formatted(.currency(code: "EUR").precision(.fractionLength(value >= 100 ? 0 : 2)))
    }
}
