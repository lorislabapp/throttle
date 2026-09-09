import Foundation

// Shared by the live MCP adapter and isolated argument-boundary tests.
extension PlanMCPTools {
    /// Resolved once per process: the descriptor names one runtime's grant and
    /// cannot change underneath it.
    static let processAuthority = PlanMCPAuthority.load()

    static func routeTaskCall(
        _ name: String, _ args: [String: Any]?,
        authority: Result<PlanMCPAuthority?, PlanMCPAuthority.Failure> = processAuthority,
        _ result: (String) -> Void, _ error: ([Any]) -> Void
    ) {
        guard let retry = try? MutationRetry.decode(args) else {
            error([-32602, "Send event_id as a UUID with expected_seq as a nonnegative safe integer."]); return
        }
        if let refusal = authorityRefusal(name, args, authority) { result(refusal); return }
        switch name {
        case "throttle_task_verdict":
            guard let taskID = args?["task_id"] as? String,
                  let author = args?["by"] as? String,
                  let verdict = args?["verdict"] as? String else {
                error([-32602, "Missing task_id, by or verdict"]); return
            }
            result(verdictText(VerdictRequest(
                project: args?["project"] as? String, taskID: taskID, author: author,
                verdict: verdict, reason: args?["reason"] as? String,
                summary: args?["summary"] as? String, retry: retry
            )))
        case "throttle_plan_read":
            result(planReadText(project: args?["project"] as? String))
        case "throttle_task_claim":
            guard let taskID = args?["task_id"] as? String,
                  let author = args?["by"] as? String else {
                error([-32602, "Missing task_id or by"]); return
            }
            result(claimText(project: args?["project"] as? String, taskID: taskID,
                             author: author, missionID: args?["mission_id"] as? String, retry: retry))
        default:
            routeEventCall(args, retry: retry, result, error)
        }
    }

    /// A present descriptor narrows every call; a broken one refuses them all;
    /// none leaves the legacy caller exactly as it was.
    static func authorityRefusal(
        _ name: String, _ args: [String: Any]?, _ authority: Result<PlanMCPAuthority?, PlanMCPAuthority.Failure>
    ) -> String? {
        let operation: PlanMCPAuthority.Operation = switch name {
        case "throttle_plan_read": .read
        case "throttle_task_claim": .claim
        case "throttle_task_verdict": .verdict
        default: .event
        }
        switch authority {
        case .failure(let failure):
            return PlanMCPAuthority.refusal(for: failure)
        case .success(let grant?):
            return grant.refusal(project: args?["project"] as? String,
                                 author: (args?["by"] as? String) ?? grant.author, operation: operation)
        case .success(nil):
            return nil
        }
    }

    private static func routeEventCall(
        _ args: [String: Any]?, retry: MutationRetry, _ result: (String) -> Void, _ error: ([Any]) -> Void
    ) {
        guard let taskID = args?["task_id"] as? String,
              let author = args?["by"] as? String,
              let type = args?["type"] as? String else {
            error([-32602, "Missing task_id, by or type"]); return
        }
        result(eventText(EventRequest(
            project: args?["project"] as? String, taskID: taskID, author: author, type: type,
            pct: args?["pct"] as? Int, note: args?["note"] as? String,
            kind: args?["kind"] as? String, ref: args?["ref"] as? String,
            reason: args?["reason"] as? String, summary: args?["summary"] as? String, retry: retry
        )))
    }
}
