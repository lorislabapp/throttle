import Foundation

/// Declarative tool contracts only. Consumers own authorization and execution.
public enum ThrottleMCPSchemas {
    /// Complete plan/knowledge catalog, independent of project state.
    public static var all: [[String: Any]] {
        planTools + [planBootstrapSchema(), projectExploreSchema()]
    }

    private static func projectProperty() -> [String: Any] {
        ["type": "string",
         "description": "Absolute path to the project. Defaults to the working directory."]
    }

    public static func planReadSchema() -> [String: Any] {
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

    public static func taskClaimSchema() -> [String: Any] {
        ["name": "throttle_task_claim",
         "description": """
         Take ownership of one task before working on it. Refused if another \
         agent already holds it. Only the holder may report progress afterwards.
         """,
         "inputSchema": ["type": "object",
                         "properties": retryProperties([
                            "project": projectProperty(),
                            "task_id": ["type": "string"],
                            "by": ["type": "string",
                                   "description": "runtime:session, e.g. codex:sess_ab"],
                            "mission_id": ["type": "string"]
                         ]),
                         "required": ["task_id", "by"]]]
    }

    public static func taskEventSchema() -> [String: Any] {
        ["name": "throttle_task_event",
         "description": """
         Report on a task you hold: progress, evidence, blocked, unblocked, \
         candidate_complete, failed or released. A candidate is only a worker's \
         claim; Throttle verifies it before done. Evidence should be checkable — \
         a commit sha, a test count, a file path.
         """,
         "inputSchema": ["type": "object",
                         "properties": retryProperties([
                            "project": projectProperty(),
                            "task_id": ["type": "string"],
                            "by": ["type": "string"],
                            "type": ["type": "string",
                                     "enum": ["progress", "evidence", "blocked", "unblocked",
                                              "candidate_complete", "failed", "released"]],
                            "pct": ["type": "integer"],
                            "note": ["type": "string"],
                            "kind": ["type": "string", "description": "evidence kind: commit, test, file"],
                            "ref": ["type": "string"],
                            "reason": ["type": "string"],
                            "summary": ["type": "string"]
                         ]),
                         "required": ["task_id", "by", "type"]]]
    }

    public static func taskVerdictSchema() -> [String: Any] {
        ["name": "throttle_task_verdict",
         "description": """
         Rule on a task awaiting counter-analysis. Only a runtime from a different \
         model family than the one that did the work may call this. Judge the \
         evidence in the log — commits, tests, diff — not the agent's own claim \
         that it is done. A task with a review rubric requires `review_report`: \
         every criterion, exact contract and candidate stamp, and only evidence \
         already in the task ledger. `rejected` must say what is missing.
         """,
         "inputSchema": ["type": "object",
                         "properties": retryProperties([
                            "project": projectProperty(),
                            "task_id": ["type": "string"],
                            "by": ["type": "string"],
                            "verdict": ["type": "string", "enum": ["verified", "rejected"]],
                            "reason": ["type": "string", "description": "what is missing, required when rejecting"],
                            "summary": ["type": "string"],
                            "review_report": reviewReportSchema()
                         ]),
                         "required": ["task_id", "by", "verdict"]]]
    }

    private static func reviewReportSchema() -> [String: Any] {
        ["type": "object",
         "properties": [
            "schemaVersion": ["type": "integer", "const": 1],
            "id": ["type": "string", "format": "uuid"],
            "taskID": ["type": "string"],
            "workContractDigest": ["type": "string"],
            "rubricDigest": ["type": "string"],
            "candidateStamp": ["type": "string"],
            "producerRuntime": ["type": "string"],
            "reviewerID": ["type": "string"],
            "reviewerRuntime": ["type": "string"],
            "reviewerKind": ["type": "string", "enum": ["model"]],
            "createdAt": ["type": "string", "format": "date-time"],
            "assessments": [
                "type": "array",
                "items": ["type": "object", "properties": [
                    "criterionID": ["type": "string"],
                    "outcome": ["type": "string",
                                "enum": ["pass", "fail", "notVerified", "notApplicable"]],
                    "evidence": ["type": "array", "items": ["type": "object", "properties": [
                        "kind": ["type": "string"], "ref": ["type": "string"]
                    ], "required": ["kind", "ref"]]],
                    "note": ["type": "string"],
                    "notApplicableReason": ["type": "string"]
                ], "required": ["criterionID", "outcome", "evidence"]]
            ]
         ],
         "required": ["schemaVersion", "id", "taskID", "workContractDigest", "rubricDigest",
                      "candidateStamp", "producerRuntime", "reviewerID", "reviewerRuntime",
                      "reviewerKind", "createdAt", "assessments"]]
    }

    public static func planBootstrapSchema() -> [String: Any] {
        ["name": "throttle_plan_bootstrap",
         "description": """
         Create a starting plan for a project that has none. Throttle surveys the \
         directory first and proposes a different tree for an empty project than \
         for one that already has code. Refuses if a plan already exists.
         """,
         "inputSchema": ["type": "object",
                         "properties": ["project": projectProperty()],
                         "required": [] as [String]]]
    }

    public static func researchRecordSchema() -> [String: Any] {
        ["name": "throttle_research_record",
         "description": """
         File one sourced finding into the project's viability dossier. Every \
         finding needs a checkable source — a URL, a file path, a local corpus id \
         — and a rating from 0 (hostile to the project) to 3 (favourable). \
         Throttle refuses to score viability while any pillar has no finding.
         """,
         "inputSchema": ["type": "object",
                         "properties": [
                            "project": projectProperty(),
                            "pillar": ["type": "string",
                                       "enum": ["feasibility", "competition", "demand", "differentiation"]],
                            "claim": ["type": "string"],
                            "source": ["type": "string"],
                            "rating": ["type": "integer", "minimum": 0, "maximum": 3],
                            "by": ["type": "string"]
                         ],
                         "required": ["pillar", "claim", "source", "rating", "by"]]]
    }

    public static func viabilitySchema() -> [String: Any] {
        ["name": "throttle_viability_read",
         "description": """
         Read the viability dossier and its verdict. Returns "insufficient \
         evidence" and names the empty pillars rather than a score, whenever \
         research is incomplete.
         """,
         "inputSchema": ["type": "object",
                         "properties": ["project": projectProperty()],
                         "required": [] as [String]]]
    }

    public static var planTools: [[String: Any]] {
        [planReadSchema(), taskClaimSchema(), taskEventSchema(), taskVerdictSchema(),
         researchRecordSchema(), viabilitySchema()]
    }

    private static func retryProperties(_ properties: [String: Any]) -> [String: Any] {
        properties.merging([
            "event_id": ["type": "string", "format": "uuid",
                         "description": "Retry UUID. Send with expected_seq; reuse both and the identical payload."],
            "expected_seq": ["type": "integer", "minimum": 0, "maximum": 9_007_199_254_740_991,
                             "description": "Task seq from throttle_plan_read. Required with event_id."
                            ]
        ]) { _, value in value }
    }
}
