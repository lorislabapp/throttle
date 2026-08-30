import Foundation

// The plan store's vocabulary. Three files back a project's plan, and each one
// has a different owner and a different lifetime:
//
// - `.throttle/plan.json` holds `Plan` — the structure. Throttle is the only
//   writer.
// - `.throttle/log/<taskId>.ndjson` holds `[TaskEvent]` — the truth. Append-only,
//   hash-chained, never rewritten.
// - `.throttle/state/<taskId>.json` holds `TaskState` — a projection derived from
//   the log. Deleting it loses nothing; it replays identically.
//
// The split exists so that a killed agent, a crashed app, or a counter-analysis
// run months later all read the same facts instead of trusting whatever an agent
// last claimed about itself.

// MARK: - Structure

enum TaskKind: String, Codable, Sendable, CaseIterable {
    case research, build, audit, decision
}

// One node of the plan. A "phase" is simply a task that has children — there is
// no second type, so rollup and dependency logic never has to branch on it.
struct PlanTask: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var parent: String?
    var order: Int
    var title: String
    var kind: TaskKind
    var dependsOn: [String]

    /// Read and displayed by lot A, interpreted by lot D (dispatcher).
    var runtimeHint: String?
    /// Read and displayed by lot A, interpreted by lot E (counter-analysis).
    /// When set, `completed` lands the task in `.review` rather than `.done`.
    var sotaGate: Bool

    init(id: String, parent: String? = nil, order: Int = 0, title: String,
         kind: TaskKind = .build, dependsOn: [String] = [],
         runtimeHint: String? = nil, sotaGate: Bool = false) {
        self.id = id
        self.parent = parent
        self.order = order
        self.title = title
        self.kind = kind
        self.dependsOn = dependsOn
        self.runtimeHint = runtimeHint
        self.sotaGate = sotaGate
    }

    // Hand-written so a plan authored by a human or by an agent survives missing
    // optional keys and an unrecognised `kind` instead of failing the whole file.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        parent = try box.decodeIfPresent(String.self, forKey: .parent)
        order = try box.decodeIfPresent(Int.self, forKey: .order) ?? 0
        title = try box.decodeIfPresent(String.self, forKey: .title) ?? box.decode(String.self, forKey: .id)
        kind = TaskKind(rawValue: try box.decodeIfPresent(String.self, forKey: .kind) ?? "") ?? .build
        dependsOn = try box.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
        runtimeHint = try box.decodeIfPresent(String.self, forKey: .runtimeHint)
        sotaGate = try box.decodeIfPresent(Bool.self, forKey: .sotaGate) ?? false
    }
}

struct Plan: Codable, Sendable, Equatable {
    var schema: Int
    var projectId: String
    var title: String
    var tasks: [PlanTask]

    init(schema: Int = 1, projectId: String, title: String, tasks: [PlanTask]) {
        self.schema = schema
        self.projectId = projectId
        self.title = title
        self.tasks = tasks
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        schema = try box.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        projectId = try box.decodeIfPresent(String.self, forKey: .projectId) ?? ""
        title = try box.decodeIfPresent(String.self, forKey: .title) ?? ""
        tasks = try box.decodeIfPresent([PlanTask].self, forKey: .tasks) ?? []
    }

    func task(_ id: String) -> PlanTask? { tasks.first { $0.id == id } }

    func children(of id: String?) -> [PlanTask] {
        tasks.filter { $0.parent == id }.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    var roots: [PlanTask] { children(of: nil) }

    var isLeafByID: [String: Bool] {
        let parents = Set(tasks.compactMap(\.parent))
        return Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, !parents.contains($0.id)) })
    }

    /// Every leaf at or below `id`, which is what a rollup averages over. A leaf
    /// asked about itself answers with itself.
    func leaves(under id: String) -> [PlanTask] {
        let kids = children(of: id)
        guard !kids.isEmpty else { return task(id).map { [$0] } ?? [] }
        return kids.flatMap { leaves(under: $0.id) }
    }
}

// MARK: - Log

enum TaskEventType: String, Codable, Sendable {
    case claimed, progress, evidence, blocked, unblocked, completed, failed, released
    /// Counter-analysis verdicts. Only a runtime from a different family may emit
    /// them: a judge scoring its own family rates it higher, and self-refinement
    /// by the same model amplifies that bias rather than cancelling it.
    case verified, rejected
}

/// One line of a task's NDJSON log. Flat rather than a payload union, because the
/// file is meant to stay readable by a human and greppable by an agent.
struct TaskEvent: Codable, Sendable, Equatable {
    var seq: Int
    var timestamp: Date
    /// `"<runtime>:<sessionId>"`, e.g. `"codex:sess_ab"`. The runtime prefix is
    /// what the UI shows and what lot E compares against.
    var author: String
    var type: TaskEventType
    /// sha256 of the previous raw line; nil on the first event.
    var prev: String?

    var pct: Int?
    var note: String?
    var kind: String?
    var ref: String?
    var reason: String?
    var summary: String?
    var missionID: String?

    init(seq: Int, timestamp: Date, author: String, type: TaskEventType, prev: String? = nil,
         pct: Int? = nil, note: String? = nil, kind: String? = nil, ref: String? = nil,
         reason: String? = nil, summary: String? = nil, missionID: String? = nil) {
        self.seq = seq
        self.timestamp = timestamp
        self.author = author
        self.type = type
        self.prev = prev
        self.pct = pct
        self.note = note
        self.kind = kind
        self.ref = ref
        self.reason = reason
        self.summary = summary
        self.missionID = missionID
    }

    /// The runtime half of `by`, used for display and for lot E's
    /// opposite-model check.
    var runtime: String { String(author.prefix(while: { $0 != ":" })) }

    // The wire format keeps the short keys: an NDJSON log is read by humans and
    // grepped by agents, where `at`/`by` earn their brevity.
    enum CodingKeys: String, CodingKey {
        case seq, prev, pct, note, kind, ref, reason, summary, missionID, type
        case timestamp = "at"
        case author = "by"
    }
}

// MARK: - Projection

enum TaskStatus: String, Codable, Sendable {
    case pending, blocked, claimed, running, review, done, failed
}

struct TaskEvidence: Codable, Sendable, Equatable, Hashable {
    var kind: String
    var ref: String
    var timestamp: Date

    enum CodingKeys: String, CodingKey {
        case kind, ref
        case timestamp = "at"
    }
}

/// Why an event was ignored. Kept in the projection rather than dropped silently,
/// because a rejected claim is exactly the kind of thing the user needs to see
/// when two agents fight over one task.
struct RejectedEvent: Codable, Sendable, Equatable {
    enum Reason: String, Codable, Sendable {
        case notOwner, alreadyOwned, outOfOrder, terminal, sameFamily
    }
    var seq: Int
    var author: String
    var type: TaskEventType
    var reason: Reason

    enum CodingKeys: String, CodingKey {
        case seq, type, reason
        case author = "by"
    }
}

struct TaskState: Codable, Sendable, Equatable {
    var status: TaskStatus = .pending
    var pct: Int = 0
    var owner: String?
    var runtime: String?
    var missionID: String?
    var startedAt: Date?
    var lastSeq: Int = 0
    var evidence: [TaskEvidence] = []
    var blockedReason: String?
    var summary: String?
    /// How many times counter-analysis sent this task back. The loop is capped,
    /// because "iterate until SOTA" without a ceiling is an infinite paid loop.
    var rejectionCount: Int = 0
    var verdictBy: String?
    /// False when a `prev` hash did not match — someone wrote the log without
    /// going through Throttle. A signal to surface, not a corruption to hide.
    var chainValid: Bool = true
    var rejected: [RejectedEvent] = []
}
