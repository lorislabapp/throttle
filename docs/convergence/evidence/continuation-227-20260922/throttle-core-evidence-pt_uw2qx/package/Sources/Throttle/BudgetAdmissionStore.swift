import Foundation

/// A durable, process-coordinated admission ledger. It limits what Throttle
/// starts next; it does not claim to stop a provider after a request leaves.
final class BudgetAdmissionStore: @unchecked Sendable {
    private let storage: BudgetAdmissionStorage

    init(projectRoot: URL) {
        storage = BudgetAdmissionStorage(projectRoot: projectRoot)
    }

    var isConfigured: Bool { storage.ledgerExists }

    func bootstrap(
        capacities: [BudgetCapacity],
        periodStartsAt: Date,
        periodEndsAt: Date
    ) throws {
        try storage.withMutationLock {
            guard !storage.ledgerExists else {
                throw BudgetAdmissionError.ledgerAlreadyExists
            }
            let ledger = BudgetAdmissionLedger(
                periodStartsAt: periodStartsAt,
                periodEndsAt: periodEndsAt,
                capacities: capacities
            )
            guard ledger.isValid else { throw BudgetAdmissionError.invalidLedger }
            try storage.write(ledger)
        }
    }

    func snapshot(now: Date = Date()) throws -> BudgetAdmissionLedger {
        try storage.withMutationLock {
            var ledger = try storage.load()
            if expireReservations(in: &ledger, now: now) {
                ledger.revision += 1
                try storage.write(ledger)
            }
            return ledger
        }
    }

    func reserve(
        _ request: BudgetReservationRequest,
        now: Date = Date()
    ) throws -> BudgetAdmissionDecision {
        try storage.withMutationLock {
            var ledger = try storage.load()
            guard now >= ledger.periodStartsAt, now < ledger.periodEndsAt else {
                throw BudgetAdmissionError.periodEnded
            }
            _ = expireReservations(in: &ledger, now: now)
            guard valid(request, ledger: ledger, now: now) else {
                throw BudgetAdmissionError.invalidRequest
            }
            if let existing = ledger.reservations.first(where: {
                $0.request.idempotencyKey == request.idempotencyKey
            }) {
                guard existing.request == request else {
                    throw BudgetAdmissionError.idempotencyConflict
                }
                return BudgetAdmissionDecision(
                    reservation: existing,
                    ledgerRevision: ledger.revision
                )
            }
            let reservation = BudgetReservation(
                id: UUID(),
                request: request,
                reservedAt: now,
                state: .reserved
            )
            ledger.reservations.append(reservation)
            guard let insufficient = firstInsufficientResource(in: ledger) else {
                ledger.revision += 1
                try storage.write(ledger)
                return BudgetAdmissionDecision(
                    reservation: reservation,
                    ledgerRevision: ledger.revision
                )
            }
            throw BudgetAdmissionError.insufficient(insufficient)
        }
    }

    func settle(
        reservationID: UUID,
        actualAmounts: [BudgetAmount],
        fidelity: BudgetSettlementFidelity,
        evidenceRef: String? = nil,
        now: Date = Date()
    ) throws -> BudgetReservation {
        try storage.withMutationLock {
            var ledger = try storage.load()
            guard let index = ledger.reservations.firstIndex(where: { $0.id == reservationID }) else {
                throw BudgetAdmissionError.unknownReservation
            }
            let current = ledger.reservations[index]
            if current.state == .settled {
                guard current.actualAmounts == actualAmounts,
                      current.settlementFidelity == fidelity,
                      current.settlementEvidenceRef == evidenceRef else {
                    throw BudgetAdmissionError.idempotencyConflict
                }
                return current
            }
            guard current.state == .reserved || current.state == .expired else {
                throw BudgetAdmissionError.reservationFinished
            }
            guard validActual(
                actualAmounts,
                reserved: current.request.amounts,
                fidelity: fidelity,
                evidenceRef: evidenceRef
            ) else { throw BudgetAdmissionError.invalidRequest }
            ledger.reservations[index].state = .settled
            ledger.reservations[index].actualAmounts = actualAmounts
            ledger.reservations[index].settlementFidelity = fidelity
            ledger.reservations[index].settlementEvidenceRef = evidenceRef
            ledger.reservations[index].finishedAt = now
            ledger.revision += 1
            try storage.write(ledger)
            return ledger.reservations[index]
        }
    }

    func release(reservationID: UUID, now: Date = Date()) throws -> BudgetReservation {
        try storage.withMutationLock {
            var ledger = try storage.load()
            guard let index = ledger.reservations.firstIndex(where: { $0.id == reservationID }) else {
                throw BudgetAdmissionError.unknownReservation
            }
            guard ledger.reservations[index].state == .reserved
                    || ledger.reservations[index].state == .expired else {
                throw BudgetAdmissionError.reservationFinished
            }
            ledger.reservations[index].state = .released
            ledger.reservations[index].finishedAt = now
            ledger.revision += 1
            try storage.write(ledger)
            return ledger.reservations[index]
        }
    }

    private func valid(
        _ request: BudgetReservationRequest,
        ledger: BudgetAdmissionLedger,
        now: Date
    ) -> Bool {
        let resources = request.amounts.map(\.resource)
        return nonempty(request.idempotencyKey)
            && nonempty(request.taskID)
            && request.idempotencyKey.count <= 256
            && request.taskID.count <= 128
            && request.expiresAt > now
            && request.expiresAt <= ledger.periodEndsAt
            && !request.amounts.isEmpty
            && Set(resources).count == resources.count
            && request.amounts.allSatisfy { $0.value > 0 }
            && Set(resources).isSubset(of: Set(ledger.capacities.map(\.resource)))
            && request.workContractDigest.map(isDigest) ?? true
    }

    private func validActual(
        _ actual: [BudgetAmount],
        reserved: [BudgetAmount],
        fidelity: BudgetSettlementFidelity,
        evidenceRef: String?
    ) -> Bool {
        let resources = actual.map(\.resource)
        let shapeIsValid = Set(resources).count == resources.count
            && Set(resources) == Set(reserved.map(\.resource))
            && actual.allSatisfy { $0.value >= 0 }
        guard shapeIsValid else { return false }
        switch fidelity {
        case .reservedUpperBound:
            return actual == reserved && evidenceRef == nil
        case .exactMetered, .providerReported:
            return nonempty(evidenceRef ?? "")
        }
    }

    private func firstInsufficientResource(in ledger: BudgetAdmissionLedger) -> BudgetResource? {
        for capacity in ledger.capacities {
            let amounts = Dictionary(uniqueKeysWithValues: BudgetPurpose.allCases.map { purpose in
                let value = ledger.reservations
                    .filter { $0.request.purpose == purpose }
                    .reduce(0) { $0 + $1.countedAmount(for: capacity.resource) }
                return (purpose, value)
            })
            let ordinary = amounts[.ordinary, default: 0]
            let verification = amounts[.verification, default: 0]
            let release = amounts[.release, default: 0]
            let shared = capacity.total
                - capacity.protectedForVerification
                - capacity.protectedForRelease
            if ordinary > shared
                || ordinary + verification > capacity.total - capacity.protectedForRelease
                || ordinary + release > capacity.total - capacity.protectedForVerification
                || ordinary + verification + release > capacity.total {
                return capacity.resource
            }
        }
        return nil
    }

    private func expireReservations(
        in ledger: inout BudgetAdmissionLedger,
        now: Date
    ) -> Bool {
        var changed = false
        for index in ledger.reservations.indices
        where ledger.reservations[index].state == .reserved
            && ledger.reservations[index].request.expiresAt <= now {
            ledger.reservations[index].state = .expired
            ledger.reservations[index].finishedAt = now
            changed = true
        }
        return changed
    }

    private func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
