import Foundation

enum BudgetResource: String, Codable, Sendable, CaseIterable {
    case frontierTokens
    case costMinorUnits
    case wallClockSeconds
}

enum BudgetPurpose: String, Codable, Sendable, CaseIterable {
    case ordinary, verification, release
}

struct BudgetAmount: Codable, Sendable, Equatable {
    var resource: BudgetResource
    var value: Int
}

struct BudgetCapacity: Codable, Sendable, Equatable {
    var resource: BudgetResource
    var total: Int
    var protectedForVerification: Int
    var protectedForRelease: Int

    var isValid: Bool {
        total > 0
            && protectedForVerification >= 0
            && protectedForRelease >= 0
            && protectedForVerification + protectedForRelease <= total
    }
}

enum BudgetReservationState: String, Codable, Sendable {
    case reserved, settled, released, expired
}

enum BudgetSettlementFidelity: String, Codable, Sendable {
    case exactMetered
    case providerReported
    case reservedUpperBound
}

struct BudgetReservationRequest: Codable, Sendable, Equatable {
    var idempotencyKey: String
    var taskID: String
    var purpose: BudgetPurpose
    var amounts: [BudgetAmount]
    var expiresAt: Date
    var workContractDigest: String?
}

struct BudgetReservation: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var request: BudgetReservationRequest
    var reservedAt: Date
    var state: BudgetReservationState
    var actualAmounts: [BudgetAmount]?
    var settlementFidelity: BudgetSettlementFidelity?
    var settlementEvidenceRef: String?
    var finishedAt: Date?

    func countedAmount(for resource: BudgetResource) -> Int {
        switch state {
        case .reserved:
            return request.amounts.first { $0.resource == resource }?.value ?? 0
        case .settled:
            return actualAmounts?.first { $0.resource == resource }?.value ?? 0
        case .expired:
            // Expiry means Throttle lost the lease, not that it proved zero use.
            return request.amounts.first { $0.resource == resource }?.value ?? 0
        case .released:
            return 0
        }
    }

    func isValid(resources: Set<BudgetResource>, period: Range<Date>) -> Bool {
        let requestedResources = request.amounts.map(\.resource)
        let actualResources = actualAmounts?.map(\.resource) ?? []
        let requestIsValid = nonempty(request.idempotencyKey)
            && nonempty(request.taskID)
            && period.contains(reservedAt)
            && request.expiresAt > reservedAt
            && request.expiresAt <= period.upperBound
            && !requestedResources.isEmpty
            && Set(requestedResources).count == requestedResources.count
            && Set(requestedResources).isSubset(of: resources)
            && request.amounts.allSatisfy { $0.value > 0 }
            && request.workContractDigest.map(isDigest) ?? true
        guard requestIsValid else { return false }

        switch state {
        case .reserved:
            return actualAmounts == nil && settlementFidelity == nil
                && settlementEvidenceRef == nil && finishedAt == nil
        case .released, .expired:
            return actualAmounts == nil && settlementFidelity == nil
                && settlementEvidenceRef == nil && finishedAt != nil
        case .settled:
            guard let actualAmounts, let settlementFidelity, finishedAt != nil,
                  Set(actualResources) == Set(requestedResources),
                  Set(actualResources).count == actualResources.count,
                  actualAmounts.allSatisfy({ $0.value >= 0 }) else { return false }
            switch settlementFidelity {
            case .reservedUpperBound:
                return actualAmounts == request.amounts && settlementEvidenceRef == nil
            case .exactMetered, .providerReported:
                return nonempty(settlementEvidenceRef ?? "")
            }
        }
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

struct BudgetAdmissionLedger: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var revision: Int = 0
    var periodStartsAt: Date
    var periodEndsAt: Date
    var capacities: [BudgetCapacity]
    var reservations: [BudgetReservation] = []

    var isValid: Bool {
        let resources = Set(capacities.map(\.resource))
        let period = periodStartsAt..<periodEndsAt
        return schemaVersion == 1
            && periodEndsAt > periodStartsAt
            && !capacities.isEmpty
            && capacities.allSatisfy(\.isValid)
            && Set(capacities.map(\.resource)).count == capacities.count
            && Set(reservations.map(\.id)).count == reservations.count
            && Set(reservations.map(\.request.idempotencyKey)).count == reservations.count
            && reservations.allSatisfy { $0.isValid(resources: resources, period: period) }
    }
}

enum BudgetAdmissionError: Error, Equatable {
    case missingLedger
    case ledgerAlreadyExists
    case periodEnded
    case invalidLedger
    case invalidRequest
    case idempotencyConflict
    case unknownBudget(BudgetResource)
    case unsupportedUnit(BudgetResource, String)
    case insufficient(BudgetResource)
    case unknownReservation
    case reservationFinished
    case unsafeStorage
    case mutationBusy
    case writeNotDurable
}

extension BudgetAdmissionError: CustomStringConvertible {
    var description: String {
        switch self {
        case .missingLedger: return "the budget ledger is missing."
        case .ledgerAlreadyExists: return "the budget ledger already exists."
        case .periodEnded: return "the configured budget period is not active."
        case .invalidLedger: return "the budget ledger is invalid."
        case .invalidRequest: return "the budget reservation is invalid."
        case .idempotencyConflict: return "the same budget operation names different intent."
        case .unknownBudget(let resource):
            return "the work contract has no exact \(resource.rawValue) budget."
        case .unsupportedUnit(let resource, let unit):
            return "the \(resource.rawValue) budget uses unsupported unit '\(unit)'."
        case .insufficient(let resource): return "insufficient \(resource.rawValue) budget remains."
        case .unknownReservation: return "the budget reservation is unknown."
        case .reservationFinished: return "the budget reservation is already finished."
        case .unsafeStorage: return "the budget ledger storage is unsafe."
        case .mutationBusy: return "the budget ledger is busy."
        case .writeNotDurable: return "the budget ledger could not be durably written."
        }
    }
}

struct BudgetAdmissionDecision: Sendable, Equatable {
    var reservation: BudgetReservation
    var ledgerRevision: Int
    /// This ledger controls only Throttle's own future admissions.
    var externalEnforcement: BackendControlFidelity = .unavailable
}

enum BackendControlFidelity: String, Codable, Sendable {
    case exact
    case betweenRequests
    case estimated
    case unavailable
}

enum BackendLocation: String, Codable, Sendable {
    case device, localNetwork, cloud, unknown
}

struct BackendControl: Codable, Sendable, Equatable {
    var name: String
    var fidelity: BackendControlFidelity
    var evidenceRef: String?
}

struct BackendCapabilityProfile: Codable, Sendable, Equatable, Identifiable {
    var schemaVersion: Int = 1
    var id: String
    var model: String?
    var provider: String
    var billingAccountRef: String?
    var harness: String
    var executor: String
    var processingLocation: BackendLocation
    var executionLocation: BackendLocation
    var eventVisibility: BackendControlFidelity
    var controls: [BackendControl]
    var observedAt: Date
    var evidenceRefs: [String]

    var isValid: Bool {
        schemaVersion == 1
            && nonempty(id)
            && nonempty(provider)
            && nonempty(harness)
            && nonempty(executor)
            && !controls.isEmpty
            && Set(controls.map(\.name)).count == controls.count
            && controls.allSatisfy { control in
                nonempty(control.name)
                    && (control.fidelity == .unavailable
                        || nonempty(control.evidenceRef ?? ""))
            }
            && !evidenceRefs.isEmpty
            && evidenceRefs.allSatisfy(nonempty)
    }

    private func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
