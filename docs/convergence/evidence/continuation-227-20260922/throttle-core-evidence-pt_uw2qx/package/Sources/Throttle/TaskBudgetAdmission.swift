import Foundation

/// Converts an explicitly configured WorkContract into a durable hold before a
/// task session starts. Missing configuration keeps legacy plans working; once a
/// ledger exists, every configured resource must be exact and correctly unitized.
enum TaskBudgetAdmission {
    static func reserveIfConfigured(
        task: PlanTask,
        missionID: UUID,
        projectRoot: URL,
        now: Date = Date()
    ) throws -> BudgetAdmissionDecision? {
        let store = BudgetAdmissionStore(projectRoot: projectRoot)
        guard store.isConfigured else { return nil }
        guard let contract = task.workContract,
              let contractDigest = contract.digest else {
            throw BudgetAdmissionError.invalidRequest
        }
        let ledger = try store.snapshot(now: now)
        let amounts = try ledger.capacities.map { capacity in
            try amount(for: capacity.resource, in: contract.budget)
        }
        return try store.reserve(
            BudgetReservationRequest(
                idempotencyKey: "launch:\(task.id):\(missionID.uuidString)",
                taskID: task.id,
                purpose: contract.budget.purpose,
                amounts: amounts,
                expiresAt: expiration(
                    budget: contract.budget,
                    now: now,
                    periodEnd: ledger.periodEndsAt
                ),
                workContractDigest: contractDigest
            ),
            now: now
        )
    }

    /// Until a provider or local meter supplies exact usage, keep the reserved
    /// upper bound as consumed. This is labelled, never presented as measured
    /// usage, and can later be reconciled with real evidence.
    static func settleUpperBound(
        reservationID: UUID,
        projectRoot: URL,
        now: Date = Date()
    ) throws {
        let store = BudgetAdmissionStore(projectRoot: projectRoot)
        let ledger = try store.snapshot(now: now)
        guard let reservation = ledger.reservations.first(where: { $0.id == reservationID }) else {
            throw BudgetAdmissionError.unknownReservation
        }
        _ = try store.settle(
            reservationID: reservationID,
            actualAmounts: reservation.request.amounts,
            fidelity: .reservedUpperBound,
            now: now
        )
    }

    private static func amount(
        for resource: BudgetResource,
        in budget: WorkflowBudgetContract
    ) throws -> BudgetAmount {
        let value: WorkflowBudgetAmount
        let requiredUnit: String
        switch resource {
        case .frontierTokens:
            value = budget.tokenLimit
            requiredUnit = "tokens"
        case .costMinorUnits:
            value = budget.costLimit
            requiredUnit = "minor-currency-unit"
        case .wallClockSeconds:
            value = budget.wallClockLimit
            requiredUnit = "seconds"
        }
        guard value.unit == requiredUnit else {
            throw BudgetAdmissionError.unsupportedUnit(resource, value.unit)
        }
        guard value.knowledge == .exact, let exact = value.value else {
            throw BudgetAdmissionError.unknownBudget(resource)
        }
        return BudgetAmount(resource: resource, value: exact)
    }

    private static func expiration(
        budget: WorkflowBudgetContract,
        now: Date,
        periodEnd: Date
    ) -> Date {
        guard budget.wallClockLimit.knowledge == .exact,
              budget.wallClockLimit.unit == "seconds",
              let seconds = budget.wallClockLimit.value else { return periodEnd }
        return min(periodEnd, now.addingTimeInterval(TimeInterval(seconds)))
    }
}
