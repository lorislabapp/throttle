import Foundation

/// Writes a person's decision on a plan task of kind `.decision`.
///
/// It goes through the same append-only, hash-chained log as agent work: the
/// person claims the task and completes it with the choice and the reason as
/// its summary. The projection then does what it already does for any work:
/// an ungated decision is done at once, and a SOTA-gated one waits in review
/// until a model from another family records a verdict. A person and an agent
/// never share a runtime family, so that review is always independent.
enum HumanDecisionRecorder {

    /// Runtime family written for a person. `TaskEvent.runtime` reads the part
    /// before the colon, which is what the independence rule compares.
    static let runtime = "human"

    enum RecordError: Error, Equatable {
        case unknownTask
        case notADecision
        /// Only a decision nobody holds, and not waiting on its dependencies, can be settled.
        case notOpen(TaskStatus)
        case emptyChoice
    }

    /// Identity of one attempt. Keeping it across a retry makes the write
    /// idempotent: the store returns the events already written instead of
    /// appending them twice.
    struct Attempt: Sendable, Equatable {
        var claimID = UUID()
        var completionID = UUID()
    }

    /// What the person wrote: the choice, and why.
    struct Entry: Sendable, Equatable {
        var choice: String
        var rationale: String = ""
    }

    static func summary(choice: String, rationale: String) -> String {
        let choice = choice.trimmingCharacters(in: .whitespacesAndNewlines)
        let rationale = rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        return rationale.isEmpty ? choice : "\(choice) — \(rationale)"
    }

    /// Returns the task's state after the write, as the projection reads it.
    @discardableResult
    static func record(
        _ entry: Entry, taskID: String, decidedBy: String, attempt: Attempt, store: PlanStore
    ) throws -> TaskState {
        let now = Date()
        let trimmed = entry.choice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RecordError.emptyChoice }
        let resolved = try store.resolveAll()
        guard let task = resolved.plan.task(taskID) else { throw RecordError.unknownTask }
        guard task.kind == .decision else { throw RecordError.notADecision }
        let state = resolved.states[taskID] ?? TaskState()
        let author = "\(runtime):\(decidedBy)"

        let alreadyClaimed = state.status == .claimed && state.owner == author
        guard state.status == .pending || alreadyClaimed else { throw RecordError.notOpen(state.status) }

        var claim = TaskEvent(seq: 0, timestamp: now, author: author, type: .claimed)
        claim.eventID = attempt.claimID
        try store.append(claim, to: taskID)

        var completion = TaskEvent(seq: 0, timestamp: now, author: author, type: .completed,
                                   summary: summary(choice: trimmed, rationale: entry.rationale))
        completion.eventID = attempt.completionID
        try store.append(completion, to: taskID)

        return try store.state(for: taskID)
    }
}
