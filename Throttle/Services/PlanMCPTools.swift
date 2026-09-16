import Foundation

/// The three plan tools exposed over MCP, kept out of `ThrottleMCPServer` so that
/// file stays a router rather than a grab bag.
///
/// Every call names its project explicitly or falls back to the agent's working
/// directory, because one Throttle process serves sessions sitting in different
/// repositories at the same time.
enum PlanMCPTools {

    static func store(_ project: String?) -> PlanStore {
        let path = project ?? FileManager.default.currentDirectoryPath
        return PlanStore(projectRoot: URL(fileURLWithPath: path, isDirectory: true))
    }

    // MARK: - Verdict

    struct VerdictRequest {
        var project: String?
        var taskID: String
        var author: String
        var verdict: String
        var reason: String?
        var summary: String?
        var reviewReport: WorkflowReviewReport?
        var retry = MutationRetry()
    }

    // MARK: - Read

    static func planReadText(project: String?) -> String {
        let store = store(project)
        guard let resolved = try? store.resolveAll() else {
            return "No plan here. Throttle expects .throttle/plan.json at the project root."
        }
        var out = ["PLAN — \(resolved.plan.title)"]
        appendTree(resolved.plan, resolved.states, parent: nil, depth: 0, into: &out)

        let actionable = self.actionable(resolved.plan, resolved.states)
        out.append("")
        if actionable.isEmpty {
            out.append("ACTIONABLE NOW: none — every unblocked task is already held or finished.")
        } else {
            out.append("ACTIONABLE NOW:")
            out.append(contentsOf: actionable.map { "  \($0.id)  \($0.title)"
                + ($0.runtimeHint.map { "  (suggested: \($0))" } ?? "") })
        }
        return out.joined(separator: "\n")
    }

    private static func appendTree(_ plan: Plan, _ states: [String: TaskState],
                                   parent: String?, depth: Int, into out: inout [String]) {
        for task in plan.children(of: parent) {
            let state = states[task.id] ?? TaskState()
            let indent = String(repeating: "  ", count: depth)
            var line = "\(indent)\(task.id)  \(task.title)  [\(state.status.rawValue) \(state.pct)%]"
                + " seq=\(state.lastSeq)"
            // Only while it is actually being worked on: "held by" next to a
            // finished task reads as if someone is still on it.
            if let owner = state.owner, state.status == .claimed || state.status == .running
                || state.status == .blocked || state.status == .review {
                line += "  held by \(owner)"
            }
            if let blocked = state.blockedReason, state.status == .blocked { line += "  waiting on \(blocked)" }
            if !state.chainValid { line += "  ⚠︎ log chain broken" }
            out.append(line)
            appendTree(plan, states, parent: task.id, depth: depth + 1, into: &out)
        }
    }

    /// A task is actionable when it is a leaf, unheld, unfinished, and every
    /// dependency is done. Parents are never actionable — you do the leaves.
    private static func actionable(_ plan: Plan, _ states: [String: TaskState]) -> [PlanTask] {
        let isLeaf = plan.isLeafByID
        return plan.tasks.filter { task in
            guard isLeaf[task.id] == true else { return false }
            let state = states[task.id] ?? TaskState()
            guard state.owner == nil, state.status == .pending || state.status == .blocked else { return false }
            return task.dependsOn.allSatisfy { states[$0]?.status == .done }
        }.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    // MARK: - Write

    /// Grouped rather than passed loose: the tool takes ten fields, and a long
    /// positional signature is exactly where a `reason` quietly lands in `ref`.
    struct EventRequest {
        var project: String?
        var taskID: String
        var author: String
        var type: String
        var pct: Int?
        var note: String?
        var kind: String?
        var ref: String?
        var reason: String?
        var summary: String?
        var retry = MutationRetry()
    }

    static func eventText(_ request: EventRequest) -> String {
        do {
            return try store(request.project).mutate { eventText(request, store: $0) }
        } catch {
            return "Refused: the plan mutation could not be safely persisted."
        }
    }

    private static func eventText(_ request: EventRequest, store: PlanStore) -> String {
        let taskID = request.taskID
        let author = request.author
        // Split so the sentence is true: `checked` and `integrated` are perfectly
        // known event types, they are simply not an agent's to write.
        guard let eventType = TaskEventType(rawValue: request.type) else {
            return "Refused: unknown event type '\(request.type)'."
        }
        let allowed: Set<TaskEventType> = [.progress, .evidence, .blocked, .unblocked,
                                           .candidateComplete, .failed, .released]
        guard allowed.contains(eventType) else {
            return "Refused: '\(request.type)' is not an agent's to write."
                + " Use throttle_task_claim to take a task; checks and integrations are Throttle's to write."
        }
        guard let plan = try? store.loadPlan(), let task = plan.task(taskID) else {
            return "Refused: no task \(taskID) in this plan."
        }
        var event = TaskEvent(seq: 0, timestamp: Date(), author: author, type: eventType,
                              pct: request.pct, note: request.note, kind: request.kind,
                              ref: request.ref, reason: request.reason, summary: request.summary)
        if let replay = retryResponse(&event, retry: request.retry, taskID: taskID, store: store) { return replay }
        guard let current = try? store.state(for: taskID) else {
            return "Refused: could not read the log for \(taskID)."
        }
        guard let owner = current.owner else {
            return "Refused: nobody holds \(taskID). Claim it first."
        }
        guard owner == author else {
            return "Refused: \(taskID) is held by \(owner), not \(author)."
        }
        if eventType == .candidateComplete,
           let refusal = recipeRefusal(
               task: task,
               author: author,
               project: request.project,
               store: store
        ) {
            return refusal
        }

        if let refusal = budgetSettlementRefusal(
            eventType: eventType,
            state: current,
            store: store
        ) {
            return refusal
        }

        guard (try? store.append(event, to: taskID)) != nil,
              let after = try? store.state(for: taskID) else {
            return "Refused: could not write the log for \(taskID)."
        }
        return eventResponse(taskID: taskID, state: after)
    }

    /// Terminal worker events close the local hold before the plan advances. A
    /// missing meter is represented conservatively by the reserved upper bound;
    /// it is never relabelled as measured provider usage.
    private static func budgetSettlementRefusal(
        eventType: TaskEventType,
        state: TaskState,
        store: PlanStore
    ) -> String? {
        let terminal: Set<TaskEventType> = [.candidateComplete, .failed, .released]
        guard terminal.contains(eventType), let reservationID = state.budgetReservationID else {
            return nil
        }
        do {
            try TaskBudgetAdmission.settleUpperBound(
                reservationID: reservationID,
                projectRoot: store.projectRoot
            )
            return nil
        } catch {
            return "Refused: the local budget hold could not be reconciled; the task remains held."
        }
    }

    private static func eventResponse(taskID: String, state: TaskState) -> String {
        var output = "\(taskID) → \(state.status.rawValue) (\(state.pct)%)."
        if state.status == .candidate {
            output += " Awaiting Throttle's verification; the worker cannot mark it done."
        }
        if !state.chainValid {
            output += " ⚠︎ This log's hash chain does not verify — something wrote it outside Throttle."
        }
        return output
    }
}
