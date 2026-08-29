import Foundation

/// Turns a task's append-only log into its current state, and a plan's leaf states
/// into the whole tree's.
///
/// Deliberately pure: no file I/O, no clock, no actor. Every rule about who owns a
/// task, whose report counts, and when a task is really finished lives here and is
/// testable without an agent, a terminal, or a build.
enum PlanProjection {

    // MARK: - One task

    /// Replays `events` over `task`. `chainValid` comes from the store, which is
    /// the only layer that sees raw lines and can verify the `prev` hashes.
    ///
    /// Events are applied in `seq` order, not file order: an agent that appends a
    /// claim late but numbered first still wins the race, which is what makes the
    /// outcome independent of filesystem timing.
    static func project(task: PlanTask, events: [TaskEvent], chainValid: Bool = true) -> TaskState {
        var state = TaskState()
        state.chainValid = chainValid

        // Stable sort: equal seq keeps file order, so the duplicate is the one
        // rejected rather than whichever the sort happened to move.
        let ordered = events.enumerated()
            .sorted { ($0.element.seq, $0.offset) < ($1.element.seq, $1.offset) }
            .map(\.element)

        for event in ordered {
            if let reason = rejection(for: event, given: state) {
                state.rejected.append(RejectedEvent(seq: event.seq, author: event.author,
                                                    type: event.type, reason: reason))
                continue
            }
            apply(event, to: &state, gated: task.sotaGate)
            state.lastSeq = event.seq
        }
        return state
    }

    private static func isTerminal(_ status: TaskStatus) -> Bool {
        switch status {
        case .done, .failed, .review: return true
        case .pending, .blocked, .claimed, .running: return false
        }
    }

    private static func rejection(for event: TaskEvent, given state: TaskState) -> RejectedEvent.Reason? {
        // A log is append-only, so a seq that does not advance is a replay, a
        // duplicate, or an edit — never new information.
        if event.seq <= state.lastSeq { return .outOfOrder }
        if isTerminal(state.status) { return .terminal }

        if event.type == .claimed {
            return state.owner == nil ? nil : .alreadyOwned
        }
        // Anything else is a report about work in progress, and only the agent
        // holding the task may report on it.
        guard let owner = state.owner, owner == event.author else { return .notOwner }
        return nil
    }

    private static func apply(_ event: TaskEvent, to state: inout TaskState, gated: Bool) {
        switch event.type {
        case .claimed:
            state.owner = event.author
            state.runtime = event.runtime
            state.status = .claimed
            state.startedAt = state.startedAt ?? event.timestamp
            if let mission = event.missionID { state.missionID = mission }

        case .progress:
            state.status = .running
            if let pct = event.pct { state.pct = min(max(pct, 0), 100) }

        case .evidence:
            state.evidence.append(TaskEvidence(kind: event.kind ?? "note",
                                               ref: event.ref ?? "", timestamp: event.timestamp))

        case .blocked:
            state.status = .blocked
            state.blockedReason = event.reason

        case .unblocked:
            state.status = .running
            state.blockedReason = nil

        case .completed:
            state.pct = 100
            state.summary = event.summary
            // A gated task is never finished on its own agent's word; it parks in
            // review until the counter-analysis (lot E) rules on it.
            state.status = gated ? .review : .done

        case .failed:
            state.status = .failed
            state.summary = event.reason

        case .released:
            // The lease ends, the work done under it does not.
            state.owner = nil
            state.runtime = nil
            state.status = .pending
            state.blockedReason = nil
        }
    }

    // MARK: - Whole plan

    /// Combines per-task projections into the tree the UI and the dispatcher read:
    /// dependency blocking on leaves, then parent rollup, then dependency blocking
    /// on parents.
    ///
    /// `leafStates` may omit tasks entirely — an untouched task has no log, and
    /// treating that as `pending` is the whole point of not pre-seeding files.
    static func resolve(plan: Plan, leafStates: [String: TaskState]) -> [String: TaskState] {
        let isLeaf = plan.isLeafByID
        var states: [String: TaskState] = [:]
        for task in plan.tasks {
            states[task.id] = leafStates[task.id] ?? TaskState()
        }

        for task in plan.tasks where isLeaf[task.id] == true {
            applyDependencyBlock(task, in: plan, states: &states)
        }

        for task in plan.tasks where isLeaf[task.id] != true {
            let leaves = plan.leaves(under: task.id)
            guard !leaves.isEmpty else { continue }
            var rolled = states[task.id] ?? TaskState()
            let childStates = leaves.compactMap { states[$0.id] }
            rolled.pct = Int((childStates.map { Double($0.pct) }.reduce(0, +)
                              / Double(childStates.count)).rounded())
            rolled.status = rollupStatus(childStates)
            states[task.id] = rolled
        }

        for task in plan.tasks where isLeaf[task.id] != true {
            applyDependencyBlock(task, in: plan, states: &states)
        }
        return states
    }

    /// Blocking only ever applies to a task nobody has started. A running agent is
    /// not interrupted because a stale plan edit added a dependency underneath it.
    private static func applyDependencyBlock(_ task: PlanTask, in plan: Plan,
                                             states: inout [String: TaskState]) {
        guard var state = states[task.id], state.status == .pending else { return }
        guard let unmet = task.dependsOn.first(where: { states[$0]?.status != .done }) else { return }
        state.status = .blocked
        state.blockedReason = unmet
        states[task.id] = state
    }

    private static func rollupStatus(_ children: [TaskState]) -> TaskStatus {
        if children.allSatisfy({ $0.status == .done }) { return .done }
        if children.contains(where: { $0.status == .failed }) { return .failed }
        if children.contains(where: { $0.status == .running || $0.status == .claimed
                                       || $0.status == .review }) { return .running }
        if children.contains(where: { $0.status == .blocked }) { return .blocked }
        return .pending
    }
}
