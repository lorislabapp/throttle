import Foundation

// Shared by the live MCP adapter and isolated argument-boundary tests.
extension PlanMCPTools {
    /// Re-read for every call so expiration and revocation take effect in a live
    /// stdio server without relying on the runtime to restart cooperatively.
    static var processAuthority: Result<PlanMCPAuthority?, PlanMCPAuthority.Failure> {
        PlanMCPAuthority.load()
    }

    static func routeTaskCall(
        _ name: String, _ args: [String: Any]?,
        authority: Result<PlanMCPAuthority?, PlanMCPAuthority.Failure>? = nil,
        _ result: (String) -> Void, _ error: ([Any]) -> Void
    ) {
        guard let retry = try? MutationRetry.decode(args) else {
            error([-32602, "Send event_id as a UUID with expected_seq as a nonnegative safe integer."]); return
        }
        let taskTools = ["throttle_plan_read", "throttle_task_claim", "throttle_task_event", "throttle_task_verdict"]
        guard taskTools.contains(name) else {
            error([-32602, "Unknown task tool"]); return
        }
        // Production reloads after waiting for the mutation lock. Explicit
        // snapshots are useful only to trusted in-process callers and fixtures.
        let initial = authority ?? processAuthority
        let authorize = pinnedAuthorization(name, args, admitted: initial, load: { authority ?? processAuthority })
        if let refusal = authorize() { result(refusal); return }
        guard case .success(let grant?) = initial else { return }
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
                summary: args?["summary"] as? String,
                reviewReport: decodeReviewReport(args?["review_report"]),
                retry: retry, authorizeMutation: authorize, runtimeAuthority: grant
            )))
        case "throttle_plan_read":
            result(planReadText(project: args?["project"] as? String))
        case "throttle_task_claim":
            routeClaimCall(args, retry: retry, context: MutationContext(grant: grant, authorize: authorize),
                           result, error)
        default:
            routeEventCall(args, retry: retry, context: MutationContext(grant: grant, authorize: authorize),
                           result, error)
        }
    }

    private static func decodeReviewReport(_ object: Any?) -> WorkflowReviewReport? {
        guard let object, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WorkflowReviewReport.self, from: data)
    }

    /// The MCP boundary always requires an explicit grant. Absence is not
    /// ambient authority; trusted controller calls use the services directly.
    static func authorityRefusal(
        _ name: String, _ args: [String: Any]?, _ authority: Result<PlanMCPAuthority?, PlanMCPAuthority.Failure>
    ) -> String? {
        let operation: PlanMCPAuthority.Operation = switch name {
        case "throttle_plan_read", "throttle_viability_read": .read
        case "throttle_task_claim": .claim
        case "throttle_task_verdict": .verdict
        case "throttle_plan_bootstrap": .bootstrap
        case "throttle_research_record": .research
        default: .event
        }
        switch authority {
        case .failure(let failure):
            return PlanMCPAuthority.refusal(for: failure)
        case .success(let grant?):
            return grant.refusal(project: args?["project"] as? String,
                                 author: (args?["by"] as? String) ?? grant.author,
                                 operation: operation,
                                 requestedTaskID: args?["task_id"] as? String)
        case .success(nil):
            return "Refused: task tools require an explicit runtime authority grant."
        }
    }

    /// A descriptor replaced during one request must not silently widen its
    /// authority. Re-read expiry/revocation, but retain the admitted identity.
    static func pinnedAuthorization(
        _ name: String, _ args: [String: Any]?,
        admitted: Result<PlanMCPAuthority?, PlanMCPAuthority.Failure>? = nil,
        load: @escaping () -> Result<PlanMCPAuthority?, PlanMCPAuthority.Failure>
    ) -> () -> String? {
        let initial = admitted ?? load()
        return {
            if let refusal = authorityRefusal(name, args, initial) { return refusal }
            let current = load()
            if let refusal = authorityRefusal(name, args, current) { return refusal }
            guard current == initial else { return "Refused: runtime authority changed during this request." }
            return nil
        }
    }

    private struct MutationContext {
        let grant: PlanMCPAuthority
        let authorize: () -> String?
    }

    private static func routeClaimCall(
        _ args: [String: Any]?, retry: MutationRetry, context: MutationContext,
        _ result: (String) -> Void, _ error: ([Any]) -> Void
    ) {
        guard let taskID = args?["task_id"] as? String,
              let author = args?["by"] as? String else {
            error([-32602, "Missing task_id or by"]); return
        }
        if let mission = args?["mission_id"] as? String, mission != context.grant.missionID.uuidString {
            result("Refused: the claim mission must match its runtime authority."); return
        }
        result(claimText(project: args?["project"] as? String, taskID: taskID,
                         author: author, missionID: context.grant.missionID.uuidString, retry: retry,
                         authorizeMutation: context.authorize, runtimeAuthority: context.grant))
    }

    private static func routeEventCall(
        _ args: [String: Any]?, retry: MutationRetry, context: MutationContext,
        _ result: (String) -> Void, _ error: ([Any]) -> Void
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
            reason: args?["reason"] as? String, summary: args?["summary"] as? String, retry: retry,
            authorizeMutation: context.authorize, runtimeAuthority: context.grant
        )))
    }
}
