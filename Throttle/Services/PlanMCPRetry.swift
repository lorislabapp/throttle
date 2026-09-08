import CoreFoundation
import Foundation

extension PlanMCPTools {
    /// Optional for legacy callers. New callers send both fields and retain the
    /// same pair and payload across retries; a new intent needs a new UUID.
    struct MutationRetry {
        var eventID: UUID?
        var expectedSequence: Int?

        static func decode(_ arguments: [String: Any]?) throws -> Self {
            let identity = arguments?["event_id"]
            let sequence = arguments?["expected_seq"]
            if identity == nil, sequence == nil { return Self() }
            guard let text = identity as? String, let eventID = UUID(uuidString: text),
                  let number = sequence as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0,
                  number.doubleValue <= 9_007_199_254_740_991,
                  number.doubleValue.rounded() == number.doubleValue else {
                throw PlanStoreError.staleSequence
            }
            return Self(eventID: eventID, expectedSequence: number.intValue)
        }
    }

    /// Must run inside the store's mutation transaction, before ownership/status
    /// checks: a successful release or verdict may have changed those checks.
    /// A replay acknowledges historical persistence, never grants current ownership.
    static func retryAcknowledgement(_ event: inout TaskEvent, retry: MutationRetry,
                                     taskID: String, store: PlanStore) throws -> String? {
        guard let identity = retry.eventID, let expected = retry.expectedSequence else {
            guard retry.eventID == nil, retry.expectedSequence == nil else { throw PlanStoreError.staleSequence }
            return nil
        }
        guard expected >= 0 else { throw PlanStoreError.staleSequence }
        event.eventID = identity
        let history = try store.events(for: taskID)
        guard history.chainValid else { throw PlanStoreError.invalidLog(taskID) }
        if let previous = history.events.first(where: { $0.eventID == identity }) {
            guard expected == previous.seq - 1 else { throw PlanStoreError.staleSequence }
            // Server-assigned time must not turn an otherwise identical retry
            // into a conflicting payload. append compares every other field.
            event.timestamp = previous.timestamp
            let recorded = try store.append(event, to: taskID, expectedSequence: expected)
            return "Already recorded \(taskID) at seq \(recorded.seq). No new mutation."
                + " Read throttle_plan_read for current status and ownership."
        }
        guard expected == (history.events.last?.seq ?? 0) else { throw PlanStoreError.staleSequence }
        return nil
    }

    static func retryResponse(_ event: inout TaskEvent, retry: MutationRetry,
                              taskID: String, store: PlanStore) -> String? {
        do {
            return try retryAcknowledgement(&event, retry: retry, taskID: taskID, store: store)
        } catch { return "Refused: invalid retry identity, changed payload, stale sequence or unreadable history." }
    }

    static func retryProperties(_ properties: [String: Any]) -> [String: Any] {
        properties.merging([
            "event_id": ["type": "string", "format": "uuid",
                         "description": "Retry UUID. Send with expected_seq; reuse both and the identical payload."],
            "expected_seq": ["type": "integer", "minimum": 0, "maximum": 9_007_199_254_740_991,
                             "description": "Task seq from throttle_plan_read. Required with event_id."
                            ]
        ]) { _, value in value }
    }
}
