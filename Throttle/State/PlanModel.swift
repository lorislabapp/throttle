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

    /// Fires when a rejected task is picked up again automatically. Set by the
    /// cockpit, which is the only thing that can open a session.
    var onAutoRelaunch: ((TaskLauncher.LaunchPlan) -> Void)?

    /// Rejection count last acted on, per task, so a relaunch happens once per
    /// verdict and not once per filesystem event.
    private var actedOnRejection: [String: Int] = [:]

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
        // Task ids are only unique inside one plan, so everything keyed by task id
        // has to go with the project — a cached assessment or diff from the previous
        // project would otherwise be shown under a same-named task in this one.
        assessments = [:]
        diffs = [:]
        pendingVerifyCommand = nil
        integrationStep = .idle

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

    // MARK: - Integration

    /// What the button is doing right now, so the card can say which step it
    /// stopped at rather than only that something failed.
    enum IntegrationStep: String, Sendable {
        case idle, rebasing, verifying, merging
    }

    private(set) var integrationStep: IntegrationStep = .idle
    /// The command the user has been asked to allow, if any.
    private(set) var pendingVerifyCommand: String?

    /// Assessing a task shells out to git half a dozen times, so it is computed
    /// when the inspector's selection changes and cached here — never read from a
    /// SwiftUI `body`, which would run git on every draw of a scrolling list.
    private(set) var assessments: [String: Assessment] = [:]
    /// Same for the diff, fetched only when the user opens the disclosure.
    private(set) var diffs: [String: String] = [:]

    /// Where consent to run a verify command is stored. Injectable so a test suite
    /// never grants itself anything in the user's real defaults.
    var verifyConsentDefaults: UserDefaults = .standard
}

// MARK: - Integration

/// Split from the class body to stay under SwiftLint's `type_body_length`. The
/// stored properties above cannot move — `@Observable` only rewrites the class
/// body — but the sequence itself can, and `private` still reaches `root` and
/// `store` from a same-file extension.
extension PlanModel {

    private static var author: String { "throttle:app" }

    /// The task's own command wins over the project's: a task that needs a
    /// narrower check should not be forced through the whole suite.
    func verifyCommand(for taskID: String) -> String? {
        plan?.task(taskID)?.verify ?? plan?.verify
    }

    func assessment(for taskID: String) -> Assessment? { assessments[taskID] }

    func integrationDiff(for taskID: String) -> String { diffs[taskID] ?? "" }

    /// Reads what the task would merge, off the main actor. Only a `.done` task has
    /// anything to assess; anything else drops the cached entry, which is what
    /// clears the card once the merge landed.
    func refreshAssessment(for taskID: String) async {
        guard let root, state(taskID).status == .done else {
            assessments[taskID] = nil
            return
        }
        assessments[taskID] = try? await Self.offMain {
            try TaskIntegrationService.assess(taskID: taskID, in: root)
        }
    }

    func refreshDiff(for taskID: String) async {
        guard let root else { return }
        diffs[taskID] = (try? await Self.offMain {
            try TaskIntegrationService.diff(taskID: taskID, in: root)
        }) ?? ""
    }

    /// Runs rebase → verify → merge and returns nil on success, or the refusal to
    /// show. Stops at the first thing that says no; nothing is written to the base
    /// branch unless all three passed.
    ///
    /// Async because the middle step runs the project's own check command, which
    /// can take minutes — on the actor that draws, that is a frozen app.
    func integrate(taskID: String) async -> String? {
        guard integrationStep == .idle else {
            return "An integration is already running."
        }
        guard let root, let store, let task = plan?.task(taskID) else {
            return "This project has no plan to integrate against."
        }
        // Only the card gated this before. A `.review` task would have run the
        // project's verify command for nothing: `checked` is accepted only on a task
        // that reached `.done`, so the event would have been silently rejected and
        // the integration refused as unverified — after minutes of shelling out.
        guard state(taskID).status == .done else {
            return "\(taskID) is \(state(taskID).status.rawValue), not done — nothing to integrate yet."
        }
        guard let command = verifyCommand(for: taskID) else {
            return "No verify command in this plan — add `verify` to the plan or the task."
        }
        guard VerifyConsent.isGranted(project: root, command: command,
                                      defaults: verifyConsentDefaults) else {
            pendingVerifyCommand = command
            return "Throttle has not been allowed to run `\(command)` in this project yet."
        }
        pendingVerifyCommand = nil

        integrationStep = .rebasing
        let outcome = await runSequence(taskID: taskID, task: task, root: root,
                                        store: store, command: command)
        integrationStep = .idle
        reload()
        await refreshAssessment(for: taskID)
        return outcome
    }

    /// The three steps themselves, each one off the main actor with the step
    /// published between them. Split from `integrate` so the guards, the step
    /// reset and the reload all happen on exactly one path.
    private func runSequence(taskID: String, task: PlanTask, root: URL,
                             store: PlanStore, command: String) async -> String? {
        let author = Self.author
        do {
            _ = try await Self.offMain {
                try TaskIntegrationService.rebase(taskID: taskID, in: root)
            }
            integrationStep = .verifying
            let verdict = try await Self.offMain {
                try TaskIntegrationService.verify(taskID: taskID, in: root, command: command,
                                                  store: store, author: author)
            }
            guard verdict.passed else {
                return "The verification failed, so nothing was merged.\n"
                    + String(verdict.output.suffix(600))
            }
            integrationStep = .merging
            _ = try await Self.offMain {
                try TaskIntegrationService.integrate(taskID: taskID, in: root, store: store,
                                                     task: task, author: author)
            }
            return nil
        } catch let error as TaskIntegrationError {
            return Self.explain(error)
        } catch {
            return String(describing: error)
        }
    }

    func allowVerifyCommand() {
        guard let root, let command = pendingVerifyCommand else { return }
        VerifyConsent.grant(project: root, command: command, defaults: verifyConsentDefaults)
        pendingVerifyCommand = nil
    }

    /// One blocking git or shell call, run off the main actor. `PlanStore` guards
    /// itself with a lock and `TaskIntegrationService` is a stateless enum, so both
    /// are safe here; what is not safe is holding the drawing actor for minutes.
    private static func offMain<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }

    private static func explain(_ error: TaskIntegrationError) -> String {
        switch error {
        case .noWorktree(let id):
            return "\(id) has no worktree — nothing to integrate."
        case .gitFailed(let output):
            return String(output.suffix(600))
        case .rebaseAbortFailed(let rebaseOutput, let abortOutput):
            // The one case where the worktree may be left mid-rebase, so it names
            // the command that gets the agent's own state back.
            return "The rebase conflicted and could not be undone — the worktree may still "
                + "be mid-rebase. Run `git rebase --abort` in it.\n"
                + String(rebaseOutput.suffix(300)) + "\n" + String(abortOutput.suffix(300))
        case .refused(.dirty):
            return "The worktree still holds uncommitted changes."
        case .refused(.behind):
            return "The base moved — rebase again before integrating."
        case .refused(.unverified):
            return "No green check for these exact commits."
        case .refused(.ungated):
            return "SOTA-gated: counter-analysis has not ruled on it."
        }
    }
}
