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
    }

    static func verdictText(_ request: VerdictRequest) -> String {
        let taskID = request.taskID
        let author = request.author
        let verdict = request.verdict
        let reason = request.reason
        let summary = request.summary
        guard let type = TaskEventType(rawValue: verdict),
              type == .verified || type == .rejected else {
            return "Refused: verdict must be 'verified' or 'rejected'."
        }
        if type == .rejected, (reason ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return "Refused: a rejection has to say what is missing, or the next agent repeats the same work."
        }
        let store = store(request.project)
        guard let plan = try? store.loadPlan(), plan.task(taskID) != nil else {
            return "Refused: no task \(taskID) in this plan."
        }
        guard let current = try? store.state(for: taskID) else {
            return "Refused: could not read the log for \(taskID)."
        }
        guard current.status == .review else {
            return "Refused: \(taskID) is \(current.status.rawValue), not awaiting review."
        }
        let judge = String(author.prefix(while: { $0 != ":" }))
        if judge == current.runtime {
            return "Refused: \(judge) did this work. A judge from the same model family rates it"
                + " higher than it should — the verdict has to come from the other runtime."
        }

        let event = TaskEvent(seq: 0, timestamp: Date(), author: author, type: type,
                              reason: reason, summary: summary)
        guard (try? store.append(event, to: taskID)) != nil,
              let after = try? store.state(for: taskID) else {
            return "Refused: could not write the log for \(taskID)."
        }
        if after.status == .failed {
            return "\(taskID) → failed after \(after.rejectionCount) rejections. The loop stops here;"
                + " it needs a human, or a smaller task."
        }
        if after.status == .pending {
            return "\(taskID) → back to pending (rejection \(after.rejectionCount)"
                + " of \(PlanProjection.maxRejections))."
        }
        return "\(taskID) → \(after.status.rawValue)."
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

    static func claimText(project: String?, taskID: String,
                          author: String, missionID: String?) -> String {
        let store = store(project)
        guard let plan = try? store.loadPlan() else { return "Refused: no plan at this project root." }
        guard let task = plan.task(taskID) else { return "Refused: no task \(taskID) in this plan." }

        guard let current = try? store.state(for: taskID) else {
            return "Refused: could not read the log for \(taskID)."
        }
        if let owner = current.owner {
            return "Refused: \(taskID) is already held by \(owner). Pick another task from throttle_plan_read."
        }
        let unmet = task.dependsOn.filter { (try? store.state(for: $0))?.status != .done }
        if !unmet.isEmpty {
            return "Refused: \(taskID) depends on \(unmet.joined(separator: ", ")), which is not done."
        }

        let event = TaskEvent(seq: 0, timestamp: Date(), author: author,
                              type: .claimed, missionID: missionID)
        guard let written = try? store.append(event, to: taskID) else {
            return "Refused: could not write the log for \(taskID)."
        }
        var out = """
        Claimed \(taskID) — \(task.title) (seq \(written.seq)).
        You now own it: report with throttle_task_event, and release it if you stop.
        """
        if task.sotaGate {
            out += "\nThis task is SOTA-gated: `completed` parks it in review for"
                + " counter-analysis, it does not finish it."
        }
        return out
    }

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
    }

    static func eventText(_ request: EventRequest) -> String {
        let taskID = request.taskID
        let author = request.author
        // Split so the sentence is true: `checked` and `integrated` are perfectly
        // known event types, they are simply not an agent's to write.
        guard let eventType = TaskEventType(rawValue: request.type) else {
            return "Refused: unknown event type '\(request.type)'."
        }
        guard eventType != .claimed, eventType != .checked, eventType != .integrated else {
            return "Refused: '\(request.type)' is not an agent's to write."
                + " Use throttle_task_claim to take a task; checks and integrations are Throttle's to write."
        }
        let store = store(request.project)
        guard let plan = try? store.loadPlan(), plan.task(taskID) != nil else {
            return "Refused: no task \(taskID) in this plan."
        }
        guard let current = try? store.state(for: taskID) else {
            return "Refused: could not read the log for \(taskID)."
        }
        guard let owner = current.owner else {
            return "Refused: nobody holds \(taskID). Claim it first."
        }
        guard owner == author else {
            return "Refused: \(taskID) is held by \(owner), not \(author)."
        }

        let event = TaskEvent(seq: 0, timestamp: Date(), author: author, type: eventType,
                              pct: request.pct, note: request.note, kind: request.kind,
                              ref: request.ref, reason: request.reason, summary: request.summary)
        guard (try? store.append(event, to: taskID)) != nil,
              let after = try? store.state(for: taskID) else {
            return "Refused: could not write the log for \(taskID)."
        }
        var out = "\(taskID) → \(after.status.rawValue) (\(after.pct)%)."
        if after.status == .review {
            out += " Gated, so it is parked for counter-analysis rather than done."
        }
        if !after.chainValid {
            out += " ⚠︎ This log's hash chain does not verify — something wrote it outside Throttle."
        }
        return out
    }
}
