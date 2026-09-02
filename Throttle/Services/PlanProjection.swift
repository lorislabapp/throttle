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

    /// After three rejections the task stops rather than looping. The cap is the
    /// difference between a refinement loop and a paid infinite one.
    static let maxRejections = 3

    /// A task whose work has landed, whichever end of the pipeline it stopped at.
    /// Dependencies and rollups ask this rather than comparing to `.done`, so an
    /// integrated task does not silently un-satisfy what it unblocked.
    static func isFinished(_ status: TaskStatus) -> Bool {
        status == .done || status == .integrated
    }

    private static func isTerminal(_ status: TaskStatus) -> Bool {
        switch status {
        case .done, .failed, .integrated: return true
        case .pending, .blocked, .claimed, .running, .review: return false
        }
    }

    private static func isVerdict(_ type: TaskEventType) -> Bool {
        type == .verified || type == .rejected
    }

    private static func rejection(for event: TaskEvent, given state: TaskState) -> RejectedEvent.Reason? {
        // A log is append-only, so a seq that does not advance is a replay, a
        // duplicate, or an edit — never new information.
        if event.seq <= state.lastSeq { return .outOfOrder }
        // Throttle's own bookkeeping on a finished task. Neither is an agent's report,
        // so neither goes through ownership — and neither is accepted before the task
        // is actually done.
        if event.type == .checked || event.type == .integrated {
            return state.status == .done ? nil : .terminal
        }
        if isTerminal(state.status) { return .terminal }
        if isVerdict(event.type) { return verdictRejection(for: event, given: state) }
        // A task in review belongs to nobody: its author is done, and only a
        // verdict moves it.
        if state.status == .review { return .terminal }
        if event.type == .claimed { return state.owner == nil ? nil : .alreadyOwned }
        // Anything else is a report about work in progress, and only the agent
        // holding the task may report on it.
        guard let owner = state.owner, owner == event.author else { return .notOwner }
        return nil
    }

    /// A verdict only means something on work that is actually awaiting review,
    /// and only from a different model family than the one that produced it.
    private static func verdictRejection(for event: TaskEvent,
                                         given state: TaskState) -> RejectedEvent.Reason? {
        guard state.status == .review else { return .notOwner }
        guard event.runtime != state.runtime else { return .sameFamily }
        return nil
    }

    private static func apply(_ event: TaskEvent, to state: inout TaskState, gated: Bool) {
        if applyVerdict(event, to: &state) { return }

        if applyOwnerReport(event, to: &state) { return }

        switch event.type {
        case .blocked, .unblocked:
            state.status = event.type == .blocked ? .blocked : .running
            state.blockedReason = event.type == .blocked ? event.reason : nil

        case .completed:
            state.pct = 100
            state.summary = event.summary
            // A gated task is never finished on its own agent's word; it parks in
            // review until counter-analysis rules on it.
            state.status = gated ? .review : .done

        case .failed:
            state.status = .failed
            state.summary = event.reason

        case .claimed, .progress, .evidence, .verified, .rejected:
            break   // handled by applyOwnerReport / applyVerdict, before this switch

        case .checked:
            state.lastCheck = TaskCheck(ok: event.ok ?? false,
                                        stamp: event.ref ?? "",
                                        at: event.timestamp)

        case .integrated:
            state.status = .integrated
            state.integratedSHA = event.ref

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
        guard let unmet = task.dependsOn.first(where: { !isFinished(states[$0]?.status ?? .pending) })
        else { return }
        state.status = .blocked
        state.blockedReason = unmet
        states[task.id] = state
    }

    /// The three events an owner emits while working. Split out so the main
    /// switch stays inside a size a reader can hold at once.
    private static func applyOwnerReport(_ event: TaskEvent, to state: inout TaskState) -> Bool {
        switch event.type {
        case .claimed:
            state.owner = event.author
            state.runtime = event.runtime
            state.status = .claimed
            state.startedAt = state.startedAt ?? event.timestamp
            if let mission = event.missionID { state.missionID = mission }
            return true
        case .progress:
            state.status = .running
            if let pct = event.pct { state.pct = min(max(pct, 0), 100) }
            return true
        case .evidence:
            state.evidence.append(TaskEvidence(kind: event.kind ?? "note",
                                               ref: event.ref ?? "", timestamp: event.timestamp))
            return true
        default:
            return false
        }
    }

    /// Split out of `apply` so the main switch stays readable: a verdict changes
    /// ownership and the retry count, which none of the other events touch.
    private static func applyVerdict(_ event: TaskEvent, to state: inout TaskState) -> Bool {
        switch event.type {
        case .verified:
            state.status = .done
            state.verdictBy = event.author
            state.summary = event.summary ?? state.summary
            return true
        case .rejected:
            state.rejectionCount += 1
            state.verdictBy = event.author
            state.owner = nil
            state.runtime = nil
            // The work done is still real; only the claim that it was finished
            // was wrong. pct is left as reported and the status carries the truth.
            state.status = state.rejectionCount >= maxRejections ? .failed : .pending
            state.blockedReason = event.reason
            return true
        default:
            return false
        }
    }

    private static func rollupStatus(_ children: [TaskState]) -> TaskStatus {
        if children.allSatisfy({ isFinished($0.status) }) { return .done }
        if children.contains(where: { $0.status == .failed }) { return .failed }
        if children.contains(where: { $0.status == .running || $0.status == .claimed
                                       || $0.status == .review }) { return .running }
        // Blocked only when nothing in it can move. A phase with one actionable
        // leaf and one waiting on it is not blocked — reading it that way tells
        // the user there is nothing to do at the exact moment there is.
        if children.allSatisfy({ $0.status == .blocked || isFinished($0.status) }) { return .blocked }
        return .pending
    }
}
