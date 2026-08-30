import Foundation

// The dispatcher's vocabulary. Everything the advisor needs is a value, injected
// by the caller, so the decision itself never touches the filesystem, the clock
// or a process — and every rule can be tested on its own.

/// One runtime's remaining room, reduced to the worst of its windows. Both Claude
/// Code and Codex report usage as a percentage of a rolling window, so this is the
/// shape they already share.
struct RuntimeBudget: Sendable, Equatable {
    let runtime: AgentRuntime
    /// Worst window for this runtime, 0–100+.
    let usedPercent: Double
    let resetsAt: Date?

    var exhausted: Bool { usedPercent >= 100 }
    var headroomPercent: Double { max(0, 100 - usedPercent) }
}

/// How many more sessions this machine can take, derived from what sessions
/// actually cost here rather than from a constant.
struct ConcurrencyCap: Sendable, Equatable {
    let additionalSessions: Int
    let reason: String
    /// Nil when no session has been observed yet, in which case the cap is
    /// deliberately conservative rather than optimistic.
    let measuredPerSessionBytes: UInt64?
}

struct DispatchInputs: Sendable {
    let task: PlanTask
    /// Skills and MCP servers each runtime has *in this repository*.
    let capabilities: [AgentRuntime: MissionCapabilityInventory]
    let budgets: [RuntimeBudget]
    let memory: MemoryHealth
    /// The single visible knob: what one task is allowed to cost.
    let spendCapEUR: Double
    /// Estimated cost of putting one agent on this task.
    let estimatedAgentCostEUR: Double
    let now: Date
}

struct DispatchAdvice: Sendable, Equatable {
    enum Verdict: Sendable, Equatable {
        case runtime(AgentRuntime)
        /// No signal was decisive. Saying so beats dressing a guess as a choice.
        case abstain
    }
    enum Confidence: String, Sendable { case high, medium, low }

    let verdict: Verdict
    let confidence: Confidence
    /// One line per signal that actually weighed, in the order they were applied.
    let reasons: [String]
    let fanOut: Int
    /// Present only when `fanOut > 1`, because that is when it costs the user
    /// something they did not ask for.
    let tokenMultiplier: Double?
    /// Set when every runtime is exhausted, so the answer is "wait", not "pick".
    let waitUntil: Date?

    var runtime: AgentRuntime? {
        if case .runtime(let value) = verdict { return value }
        return nil
    }
}
