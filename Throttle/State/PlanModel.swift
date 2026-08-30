import Foundation
import SwiftUI

/// Backs the cockpit's Plan segment: holds one project's plan and derived state,
/// and reloads whenever an agent appends to a log.
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

    private var root: URL?
    private var store: PlanStore?
    private var watcher: PlanWatcher?

    /// Points the model at a project. Cheap to call repeatedly — rebinding to the
    /// same root is a no-op, so it can sit in `onChange` of the active tab.
    func bind(to newRoot: URL?) {
        guard newRoot?.path != root?.path else { return }
        watcher?.stop()
        watcher = nil
        root = newRoot
        selection = nil

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
}
