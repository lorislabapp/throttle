import Foundation

/// The plan read as a pipeline: which column each task sits in, what the person
/// should look at first, and a short health list. Pure, derived from the same
/// overview the project page shows, so the board and the overview never disagree.
enum PlanFlow {

    /// Columns left to right in the order work moves through them. `waiting`
    /// comes last: it is what cannot move yet, not the next thing to do.
    enum Stage: String, CaseIterable, Identifiable, Sendable {
        case toStart, working, fixing, checking, ready, shipped, waiting
        var id: String { rawValue }
    }

    struct Column: Equatable, Sendable, Identifiable {
        let stage: Stage
        let cards: [ProjectOverview.TaskItem]
        var id: String { stage.rawValue }
    }

    static func stage(of item: ProjectOverview.TaskItem) -> Stage {
        let state = item.state
        switch state.status {
        case .claimed, .running: return state.rejectionCount > 0 ? .fixing : .working
        case .failed: return .fixing
        case .candidate, .review: return .checking
        case .done: return .ready
        case .integrated: return .shipped
        case .blocked: return .waiting
        case .pending:
            guard item.waitingOn.isEmpty, state.owner == nil else { return .waiting }
            return state.rejectionCount > 0 ? .fixing : .toStart
        }
    }

    static func columns(_ overview: ProjectOverview) -> [Column] {
        let grouped = Dictionary(grouping: overview.tasks, by: stage(of:))
        return Stage.allCases.map { stage in
            Column(stage: stage, cards: (grouped[stage] ?? []).sorted { lhs, rhs in
                (lhs.lastActivity ?? .distantPast) > (rhs.lastActivity ?? .distantPast)
            })
        }
    }

    /// The single card worth looking at first: work in motion, then work that
    /// broke, then work waiting on verification, then the next task to start.
    static func focus(_ overview: ProjectOverview) -> (stage: Stage, item: ProjectOverview.TaskItem)? {
        let byStage = Dictionary(grouping: overview.tasks, by: stage(of:))
        for stage in [Stage.fixing, .working, .checking, .ready, .toStart] {
            if let item = byStage[stage]?.first { return (stage, item) }
        }
        return nil
    }

    enum Verdict: Equatable, Sendable { case good, problem, unknown }

    enum HealthKind: String, Sendable { case noFailures, proofsGreen, noDecisionWaiting, logIntact }

    struct HealthCheck: Equatable, Sendable, Identifiable {
        let kind: HealthKind
        let verdict: Verdict
        var id: String { kind.rawValue }
    }

    static func health(_ overview: ProjectOverview) -> [HealthCheck] {
        let proofs = overview.evidence.proofs
        return [
            HealthCheck(kind: .noFailures, verdict: overview.progress.count(.failed) == 0 ? .good : .problem),
            HealthCheck(kind: .proofsGreen, verdict: proofs.isEmpty ? .unknown
                        : (proofs.allSatisfy { $0.outcome == .passed } ? .good : .problem)),
            HealthCheck(kind: .noDecisionWaiting,
                        verdict: overview.decisions.contains(where: \.isOpen) ? .problem : .good),
            HealthCheck(kind: .logIntact, verdict: overview.evidence.chainValid ? .good : .problem)
        ]
    }

    /// Counts across projects for Today, per stage that asks something of someone.
    static func totals(_ overviews: [ProjectOverview]) -> [Stage: Int] {
        var totals: [Stage: Int] = [:]
        for overview in overviews {
            for item in overview.tasks { totals[stage(of: item), default: 0] += 1 }
        }
        return totals
    }
}
