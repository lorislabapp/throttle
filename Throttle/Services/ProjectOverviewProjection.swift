import Foundation

/// The project read as a person deciding what to do next: what it is for, how
/// much of it is proven, what waits on a human, what changed, what the evidence
/// says and what it costs.
///
/// Pure and read-only. Progress is counted from task statuses a verifier or an
/// integration wrote, never from the percentage agents report about themselves;
/// that figure is kept apart as `declaredPct` so a view can label it for what it is.
struct ProjectOverview: Equatable, Sendable {

    struct Objective: Equatable, Sendable {
        let text: String
        let contractRevision: Int?
        let requirements: [WorkflowRequirement]
    }

    /// Buckets in the order a reader weighs them. `pending` is work nobody
    /// started, kept so the counts add up to the total.
    enum Bucket: String, CaseIterable, Sendable {
        case integrated, verified, candidate, inProgress, blocked, failed, pending

        init(_ status: TaskStatus) {
            switch status {
            case .integrated: self = .integrated
            case .done: self = .verified
            case .candidate, .review: self = .candidate
            case .claimed, .running: self = .inProgress
            case .blocked: self = .blocked
            case .failed: self = .failed
            case .pending: self = .pending
            }
        }
    }

    struct Progress: Equatable, Sendable {
        let counts: [Bucket: Int]
        let total: Int
        /// Integrated or verified: the only tasks that count as progress.
        var proven: Int { (counts[.integrated] ?? 0) + (counts[.verified] ?? 0) }
        func count(_ bucket: Bucket) -> Int { counts[bucket] ?? 0 }
    }

    struct TaskItem: Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        let bucket: Bucket
        let state: TaskState
    }

    struct Decision: Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        let openedAt: Date?
        let bucket: Bucket
        /// A gated decision is reviewed by an agent of another family before it counts.
        let sotaGate: Bool
        /// Only an untouched decision can be settled from the overview.
        var isOpen: Bool { bucket == .pending }
    }

    struct Change: Equatable, Sendable, Identifiable {
        let taskID: String
        let taskTitle: String
        let event: TaskEvent
        var id: String { "\(taskID)#\(event.seq)" }
    }

    enum ProofOutcome: String, Sendable { case passed, failed, incomplete }

    struct Proof: Equatable, Sendable, Identifiable {
        let taskID: String
        let taskTitle: String
        let outcome: ProofOutcome
        let expected: Int?
        let passed: Int?
        let skipped: Int?
        let ranAt: Date
        var id: String { taskID }
    }

    struct Evidence: Equatable, Sendable {
        let proofs: [Proof]
        /// False as soon as one task's log fails its hash chain.
        let chainValid: Bool
        func count(_ outcome: ProofOutcome) -> Int { proofs.filter { $0.outcome == outcome }.count }
    }

    let planTitle: String
    let objective: Objective?
    let progress: Progress
    let tasks: [TaskItem]
    let declaredPct: Int?
    let decisions: [Decision]
    let changes: [Change]
    let evidence: Evidence

    /// Event types worth a line in "Changes": the ones that move a task between
    /// what a reader trusts and what they do not.
    static let changeTypes: Set<TaskEventType> = [.integrated, .verified, .rejected, .blocked, .unblocked, .failed]

    static func project(
        plan: Plan,
        states: [String: TaskState],
        events: [String: [TaskEvent]] = [:],
        changeLimit: Int = 6
    ) -> ProjectOverview {
        let isLeaf = plan.isLeafByID
        let leaves = plan.tasks.filter { isLeaf[$0.id] == true }
        let items = leaves.map { task in
            let state = states[task.id] ?? TaskState()
            return TaskItem(id: task.id, title: task.title, bucket: Bucket(state.status), state: state)
        }
        let counts = Dictionary(grouping: items, by: \.bucket).mapValues(\.count)

        let contractTask = plan.tasks.first { $0.parent == nil && $0.workContract != nil }
            ?? plan.tasks.first { $0.workContract != nil }
        let objective = contractTask?.workContract.map {
            Objective(text: $0.objective, contractRevision: $0.revision, requirements: $0.requirements)
        }

        let decisions = items
            .filter { item in
                plan.task(item.id)?.kind == .decision
                    && ![.verified, .integrated, .failed].contains(item.bucket)
            }
            .map { item in
                Decision(id: item.id, title: item.title, openedAt: item.state.startedAt, bucket: item.bucket,
                         sotaGate: plan.task(item.id)?.sotaGate ?? false)
            }

        return ProjectOverview(
            planTitle: plan.title,
            objective: objective,
            progress: Progress(counts: counts, total: items.count),
            tasks: items,
            declaredPct: declaredPct(plan: plan, states: states),
            decisions: decisions,
            changes: changes(plan: plan, events: events, limit: changeLimit),
            evidence: Evidence(proofs: proofs(items), chainValid: items.allSatisfy { $0.state.chainValid })
        )
    }

    private static func changes(plan: Plan, events: [String: [TaskEvent]], limit: Int) -> [Change] {
        let titles = Dictionary(plan.tasks.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        return events
            .flatMap { taskID, list in
                list.filter { changeTypes.contains($0.type) }
                    .map { Change(taskID: taskID, taskTitle: titles[taskID] ?? taskID, event: $0) }
            }
            .sorted {
                if $0.event.timestamp != $1.event.timestamp { return $0.event.timestamp > $1.event.timestamp }
                return $0.id < $1.id
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func proofs(_ items: [TaskItem]) -> [Proof] {
        items.compactMap { item -> Proof? in
            guard let check = item.state.lastCheck else { return nil }
            let receipt = check.receipt
            let outcome: ProofOutcome = switch receipt?.outcome {
            case .passed: .passed
            case .failed: .failed
            case .incomplete: .incomplete
            case nil: check.passed ? .passed : .failed
            }
            return Proof(taskID: item.id, taskTitle: item.title, outcome: outcome,
                         expected: receipt?.expectedTests?.count, passed: receipt?.passedTests?.count,
                         skipped: receipt?.skippedTests?.count, ranAt: receipt?.finishedAt ?? check.ranAt)
        }
        .sorted { $0.ranAt > $1.ranAt }
    }

    /// The agents' own figure, averaged over the top-level tasks exactly as the
    /// cockpit computes it. Returned only so a view can label it as declared.
    private static func declaredPct(plan: Plan, states: [String: TaskState]) -> Int? {
        let roots = plan.roots
        guard !roots.isEmpty else { return nil }
        let total = roots.map { Double(states[$0.id]?.pct ?? 0) }.reduce(0, +)
        return Int((total / Double(roots.count)).rounded())
    }
}

/// The four kinds of cost a project can carry. They are never added together:
/// a subscription quota, an invoice, a local estimate and a reserve answer four
/// different questions, and a sum of them would answer none.
struct ProjectCostReadout: Equatable, Sendable {
    enum Figure: Equatable, Sendable {
        case known(String)
        case estimated(String)
        /// Nothing measured this; the view says so instead of showing zero.
        case unmeasured
    }

    let subscriptionQuota: Figure
    let apiInvoice: Figure
    let internalEstimate: Figure
    let reserve: Figure
    /// Part of the reserve set aside for verification, when a ledger exists.
    let protectedForVerification: String?

    /// Builds the readout from what Throttle actually holds. The invoice and the
    /// subscription quota are not known per project here, so they stay unmeasured
    /// rather than borrowing a global figure.
    static func make(monthEstimateEUR: Double?, ledger: BudgetAdmissionLedger?,
                     format: (Double) -> String) -> ProjectCostReadout {
        let estimate: Figure = monthEstimateEUR.map { $0 > 0 ? .estimated(format($0)) : .unmeasured } ?? .unmeasured
        let money = ledger?.capacities.first { $0.resource == .costMinorUnits }
        return ProjectCostReadout(
            subscriptionQuota: .unmeasured,
            apiInvoice: .unmeasured,
            internalEstimate: estimate,
            reserve: money.map { .known(format(Double($0.total) / 100)) } ?? .unmeasured,
            protectedForVerification: money.flatMap {
                $0.protectedForVerification > 0 ? format(Double($0.protectedForVerification) / 100) : nil
            }
        )
    }
}
