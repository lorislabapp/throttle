import Foundation
import SwiftUI

/// Backs the cockpit's Plan segment: holds one project's plan and derived state,
/// and reloads whenever an agent appends to a log.
///
/// This file owns the plan itself — binding to a project, loading it, the tree the
/// list draws, dispatch advice, and auto-relaunch. Everything about *integrating* a
/// finished task lives in `PlanIntegrationModel.swift`: the rebase → verify → merge
/// sequence, the caches the card reads, and consent. The only piece of that half
/// which has to stay here is its stored state, because `@Observable` rewrites the
/// class body and nothing else.
///
/// Read-only by design in lot A. Nothing here writes — the only writes to
/// `.throttle/` come from agents through `PlanMCPTools`, which keeps a single
/// story about who changed what.
@MainActor
@Observable
final class PlanModel {

    private(set) var plan: Plan?
    private(set) var states: [String: TaskState] = [:]
    /// Nil while a project simply has no plan yet, which is the normal case and
    /// must not be dressed up as a failure.
    private(set) var loadError: String?
    private(set) var hasPlan = false

    var selection: String?

    /// One advice per actionable task. Computed on reload rather than on every
    /// draw, because it samples memory and reads usage snapshots.
    private(set) var advice: [String: DispatchAdvice] = [:]

    /// The single visible knob: what one task may cost. Conservative by default —
    /// a fan-out should be something the user chose, never a surprise on the bill.
    var spendCapEUR: Double {
        get { UserDefaults.standard.object(forKey: "planSpendCapEUR") as? Double ?? 1.0 }
        set { UserDefaults.standard.set(newValue, forKey: "planSpendCapEUR"); refreshAdvice() }
    }

    /// Fires when a rejected task is picked up again automatically. Set by the
    /// cockpit, which is the only thing that can open a session.
    var onAutoRelaunch: ((TaskLauncher.LaunchPlan) -> Void)?

    /// Whether any open cockpit session is working inside this directory. Set by the
    /// cockpit next to `onAutoRelaunch`, because tabs are the only thing it knows
    /// that this model does not. Nil is the honest answer for a model with no
    /// cockpit behind it — a test, or the MCP side — which has no tab to protect.
    var isDirectoryHeldBySession: ((URL) -> Bool)?

    /// Rejection count last acted on, per task, so a relaunch happens once per
    /// verdict and not once per filesystem event.
    private var actedOnRejection: [String: Int] = [:]

    /// `private(set)` rather than `private`: the integration half reads both, and
    /// Swift's access control has no "this type, across files" level.
    private(set) var root: URL?
    private(set) var store: PlanStore?
    private var watcher: PlanWatcher?

    /// Points the model at a project. Cheap to call repeatedly — rebinding to the
    /// same root is a no-op, so it can sit in `onChange` of the active tab.
    func bind(to newRoot: URL?) {
        guard newRoot?.path != root?.path else { return }
        watcher?.stop()
        watcher = nil
        root = newRoot
        selection = nil
        // Task ids are only unique inside one plan, so everything keyed by task id
        // has to go with the project — a cached assessment, error or diff from the
        // previous project would otherwise be shown under a same-named task in this
        // one. The steps in flight are keyed by project root and survive: a tab
        // switch does not cancel a rebase already running in a worktree.
        integration.forgetCaches()

        guard let newRoot else {
            store = nil
            plan = nil
            states = [:]
            hasPlan = false
            return
        }
        store = PlanStore(projectRoot: newRoot)
        let watcher = PlanWatcher(projectRoot: newRoot) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        watcher.start()
        self.watcher = watcher
        reload()
    }

    func reload() {
        guard let store else { return }
        hasPlan = store.planExists()
        guard hasPlan else {
            plan = nil
            states = [:]
            loadError = nil
            return
        }
        do {
            let resolved = try store.resolveAll()
            plan = resolved.plan
            states = resolved.states
            loadError = nil
            refreshAdvice()
            autoRelaunchRejectedTasks()
        } catch {
            loadError = String(describing: error)
        }
    }

    /// Advises only on tasks that could actually start. Advising on a task nobody
    /// can pick up would be noise dressed as guidance.
    func refreshAdvice() {
        guard let plan, let root else { advice = [:]; return }
        let memory = SystemMemoryService.sample()
        let budgets = DispatchBudget.current()
        let capabilities = Dictionary(uniqueKeysWithValues: [AgentRuntime.claudeCode, .codex].map {
            ($0, MissionRuntimeService.capabilityInventory(runtime: $0, cwd: root.path))
        })
        let cost = DispatchBudget.estimatedAgentCostEUR(sessionsLastWeek: max(1, memory.claudeCount))
        let isLeaf = plan.isLeafByID
        let cap = spendCapEUR

        var next: [String: DispatchAdvice] = [:]
        for task in plan.tasks where isLeaf[task.id] == true {
            let state = self.state(task.id)
            guard state.owner == nil, state.status == .pending else { continue }
            next[task.id] = DispatchAdvisor.advise(DispatchInputs(
                task: task, capabilities: capabilities, budgets: budgets, memory: memory,
                spendCapEUR: cap, estimatedAgentCostEUR: cost, now: Date()))
        }
        advice = next
    }

    /// The one automatic session start in the app, gated by the spend cap rather
    /// than by a judgement call. Skips any task the advisor is unsure about:
    /// spending money on a guess is worse than waiting for the user.
    private func autoRelaunchRejectedTasks() {
        guard let plan, let store, onAutoRelaunch != nil else { return }
        let cost = DispatchBudget.estimatedAgentCostEUR(
            sessionsLastWeek: max(1, SystemMemoryService.sample().claudeCount))

        for task in plan.tasks {
            let taskState = state(task.id)
            guard taskState.rejectionCount > 0,
                  actedOnRejection[task.id] != taskState.rejectionCount else { continue }

            let attempts = ((try? store.events(for: task.id).events) ?? [])
                .filter { $0.type == .claimed }.count
            let decision = AutoRelaunchPolicy.decide(state: taskState, attemptsSoFar: attempts,
                                                     spendCapEUR: spendCapEUR,
                                                     estimatedAgentCostEUR: cost)
            actedOnRejection[task.id] = taskState.rejectionCount
            guard decision.relaunch, let runtime = advice[task.id]?.runtime else { continue }
            if let launch = try? prepareLaunch(taskID: task.id, runtime: runtime) {
                onAutoRelaunch?(launch)
            }
        }
    }

    /// Prepares a task for launch. Returns the plan for the cockpit to open —
    /// this model never opens a session itself.
    func prepareLaunch(taskID: String, runtime: AgentRuntime) throws -> TaskLauncher.LaunchPlan {
        guard let root else { throw TaskLauncher.LaunchError.unknownTask(taskID) }
        let author = "\(runtime.rawValue):\(UUID().uuidString.prefix(8))"
        let launch = try TaskLauncher.prepare(taskID: taskID, runtime: runtime,
                                              repo: root, author: author)
        reload()
        return launch
    }

    /// What Throttle sees in this project before any plan exists — used to say
    /// what kind of starting plan it would propose, rather than offering a
    /// generic button.
    var survey: ProjectIntakeService.Survey? {
        guard let root, !hasPlan else { return nil }
        return ProjectIntakeService.survey(repo: root)
    }

    /// Writes a starting plan shaped by the survey. Refuses over an existing plan
    /// at the store level, so a double click cannot discard held tasks.
    func bootstrap() {
        guard let root, let survey else { return }
        do {
            try PlanStore(projectRoot: root).bootstrap(PlanTemplate.starter(for: survey))
            reload()
        } catch {
            loadError = String(describing: error)
        }
    }

    /// The log behind one task, for the inspector. Read on demand rather than kept
    /// in memory: a plan can hold hundreds of tasks and the user looks at one.
    func events(for taskID: String) -> [TaskEvent] {
        (try? store?.events(for: taskID).events) ?? []
    }

    struct Row: Identifiable {
        let task: PlanTask
        let depth: Int
        var id: String { task.id }
    }

    /// The tree flattened depth-first in display order.
    var rows: [Row] {
        guard let plan else { return [] }
        var out: [Row] = []
        func walk(_ parent: String?, _ depth: Int) {
            for task in plan.children(of: parent) {
                out.append(Row(task: task, depth: depth))
                walk(task.id, depth + 1)
            }
        }
        walk(nil, 0)
        return out
    }

    func state(_ id: String) -> TaskState { states[id] ?? TaskState() }

    var overallPct: Int {
        guard let plan, !plan.roots.isEmpty else { return 0 }
        let pcts = plan.roots.map { Double(state($0.id).pct) }
        return Int((pcts.reduce(0, +) / Double(pcts.count)).rounded())
    }

    // MARK: - Integration state

    /// The whole of the integration half's state, in one property rather than five.
    ///
    /// It has to be stored here — `@Observable` only rewrites the class body — while
    /// everything that reads and writes it lives in `PlanIntegrationModel.swift`, so
    /// it cannot be `private(set)`. Keeping it as one value is what stops that file
    /// boundary from widening five separate properties: the accessors the rest of
    /// the app uses (`integrationStep`, `assessment(for:)`, …) are still narrow, and
    /// they are all in that file.
    var integration = IntegrationState()

    /// Where consent to run a verify command is stored. Injectable so a test suite
    /// never grants itself anything in the user's real defaults.
    var verifyConsentDefaults: UserDefaults = .standard
}
