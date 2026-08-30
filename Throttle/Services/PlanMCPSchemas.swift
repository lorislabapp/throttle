import Foundation

// The MCP tool schemas for the plan tools, kept beside their implementations but
// in their own file: schema text is documentation an agent reads, and it grows
// every time a refusal needs explaining.
extension PlanMCPTools {

    private static func projectProperty() -> [String: Any] {
        ["type": "string",
         "description": "Absolute path to the project. Defaults to the working directory."]
    }

    static func planReadSchema() -> [String: Any] {
        ["name": "throttle_plan_read",
         "description": """
         Read this project's plan: the task tree with status and progress, plus \
         exactly which tasks are actionable right now — dependencies met and \
         nobody holding them. Call this before picking up work.
         """,
         "inputSchema": ["type": "object",
                         "properties": ["project": projectProperty()],
                         "required": [] as [String]]]
    }

    static func taskClaimSchema() -> [String: Any] {
        ["name": "throttle_task_claim",
         "description": """
         Take ownership of one task before working on it. Refused if another \
         agent already holds it. Only the holder may report progress afterwards.
         """,
         "inputSchema": ["type": "object",
                         "properties": [
                            "project": projectProperty(),
                            "task_id": ["type": "string"],
                            "by": ["type": "string",
                                   "description": "runtime:session, e.g. codex:sess_ab"],
                            "mission_id": ["type": "string"]
                         ],
                         "required": ["task_id", "by"]]]
    }

    static func taskEventSchema() -> [String: Any] {
        ["name": "throttle_task_event",
         "description": """
         Report on a task you hold: progress, evidence, blocked, unblocked, \
         completed, failed or released. Evidence should be checkable — a commit \
         sha, a test count, a file path.
         """,
         "inputSchema": ["type": "object",
                         "properties": [
                            "project": projectProperty(),
                            "task_id": ["type": "string"],
                            "by": ["type": "string"],
                            "type": ["type": "string",
                                     "enum": ["progress", "evidence", "blocked", "unblocked",
                                              "completed", "failed", "released"]],
                            "pct": ["type": "integer"],
                            "note": ["type": "string"],
                            "kind": ["type": "string", "description": "evidence kind: commit, test, file"],
                            "ref": ["type": "string"],
                            "reason": ["type": "string"],
                            "summary": ["type": "string"]
                         ],
                         "required": ["task_id", "by", "type"]]]
    }

    static func taskVerdictSchema() -> [String: Any] {
        ["name": "throttle_task_verdict",
         "description": """
         Rule on a task awaiting counter-analysis. Only a runtime from a different \
         model family than the one that did the work may call this. Judge the \
         evidence in the log — commits, tests, diff — not the agent's own claim \
         that it is done. `rejected` must say what is missing.
         """,
         "inputSchema": ["type": "object",
                         "properties": [
                            "project": projectProperty(),
                            "task_id": ["type": "string"],
                            "by": ["type": "string"],
                            "verdict": ["type": "string", "enum": ["verified", "rejected"]],
                            "reason": ["type": "string", "description": "what is missing, required when rejecting"],
                            "summary": ["type": "string"]
                         ],
                         "required": ["task_id", "by", "verdict"]]]
    }

    static var schemas: [[String: Any]] {
        [planReadSchema(), taskClaimSchema(), taskEventSchema(), taskVerdictSchema()]
    }

    /// Advertised only where a plan exists, so a session in an unplanned repo pays
    /// nothing in schema tokens for three tools it cannot use.
    static func hasPlan() -> Bool {
        store(nil).planExists()
    }

}
