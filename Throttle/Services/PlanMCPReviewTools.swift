import Foundation

extension PlanMCPTools {
    static func verdictText(_ request: VerdictRequest) -> String {
        do {
            return try store(request.project).mutate {
                if let refusal = request.authorizeMutation() { return refusal }
                return verdictText(request, store: $0)
            }
        } catch {
            return "Refused: the plan mutation could not be safely persisted."
        }
    }

    private static func verdictText(_ request: VerdictRequest, store: PlanStore) -> String {
        guard let type = TaskEventType(rawValue: request.verdict),
              type == .verified || type == .rejected else {
            return "Refused: verdict must be 'verified' or 'rejected'."
        }
        if type == .rejected,
           (request.reason ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return "Refused: a rejection has to say what is missing, or the next agent repeats the same work."
        }
        guard let plan = try? store.loadPlan(), let task = plan.task(request.taskID) else {
            return "Refused: no task \(request.taskID) in this plan."
        }
        var event = TaskEvent(
            seq: 0,
            timestamp: Date(),
            author: request.author,
            type: type,
            reason: request.reason,
            summary: request.summary,
            reviewReport: request.reviewReport
        )
        event.authorityGrantID = request.runtimeAuthority?.grantID
        event.missionID = request.runtimeAuthority?.missionID.uuidString
        if let replay = retryResponse(
            &event,
            retry: request.retry,
            taskID: request.taskID,
            store: store
        ) { return replay }
        guard let current = try? store.state(for: request.taskID) else {
            return "Refused: could not read the log for \(request.taskID)."
        }
        if let refusal = reviewerRefusal(request, task: task, state: current, type: type) {
            return refusal
        }
        return persistVerdict(event, request: request, store: store)
    }

    private static func reviewerRefusal(
        _ request: VerdictRequest,
        task: PlanTask,
        state: TaskState,
        type: TaskEventType
    ) -> String? {
        guard state.status == .review else {
            return "Refused: \(request.taskID) is \(state.status.rawValue), not awaiting review."
        }
        let judge = String(request.author.prefix(while: { $0 != ":" }))
        guard judge != state.runtime else {
            return "Refused: \(judge) did this work. A judge from the same model family rates it"
                + " higher than it should — the verdict has to come from the other runtime."
        }
        guard task.workContract?.reviewRubric != nil else { return nil }
        guard let report = request.reviewReport else {
            return "Refused: this task requires a structured fidelity and quality review report."
        }
        guard report.reviewerKind == .model, report.reviewerID == request.author else {
            return "Refused: the MCP verdict can record only this runtime's own model review."
        }
        do {
            let evaluation = try WorkflowReviewGate.evaluate(report, task: task, state: state)
            let expected: TaskEventType = evaluation.decision == .accepted ? .verified : .rejected
            return type == expected
                ? nil : "Refused: the structured criteria require '\(expected.rawValue)'."
        } catch {
            return "Refused: \(error)"
        }
    }

    private static func persistVerdict(
        _ event: TaskEvent,
        request: VerdictRequest,
        store: PlanStore
    ) -> String {
        if let refusal = request.authorizeMutation() { return refusal }
        guard (try? store.append(event, to: request.taskID)) != nil,
              let after = try? store.state(for: request.taskID) else {
            return "Refused: could not write the log for \(request.taskID)."
        }
        if after.status == .failed {
            return "\(request.taskID) → failed after \(after.rejectionCount) rejections. The loop stops here;"
                + " it needs a human, or a smaller task."
        }
        if after.status == .pending {
            return "\(request.taskID) → back to pending (rejection \(after.rejectionCount)"
                + " of \(PlanProjection.maxRejections))."
        }
        return "\(request.taskID) → \(after.status.rawValue)."
    }
}
