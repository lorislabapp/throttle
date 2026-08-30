import Foundation

/// Recommends which runtime should take a task, and how many agents it may use.
///
/// Advisory only: nothing here starts a session. The 2026-08-18 research settled
/// this — router advisory plus abstention, never auto-routing — so the cost of a
/// wrong recommendation stays zero.
///
/// Pure, like `PlanProjection`: budgets, memory and capabilities are injected as
/// values. That is what lets a test assert the same rule on a 16 GB machine and a
/// 64 GB one by changing only the measured input.
enum DispatchAdvisor {

    /// Below this share of physical memory left free, adding a session is a bet
    /// against the user's machine rather than a decision.
    private static let safetyMarginFraction = 0.15

    /// Used only until a real session has been observed. Not a tuning constant to
    /// calibrate — a placeholder that measurement replaces on first sight.
    private static let unmeasuredSessionBytes: UInt64 = 1_500_000_000

    static func advise(_ input: DispatchInputs) -> DispatchAdvice {
        var reasons: [String] = []
        let cap = concurrencyCap(memory: input.memory)

        // 1 — Capability is the only hard signal available today: which runtime
        // actually has the skills and MCP servers this repository offers is a
        // filesystem fact, not a guess about model temperament.
        if let decisive = capabilityDecision(input) {
            reasons.append(decisive.reason)
            if let budget = budget(for: decisive.runtime, in: input), budget.exhausted {
                reasons.append("\(decisive.runtime.shortLabel) is out of window,"
                               + " so the capability match cannot be used")
            } else {
                let fan = fanOut(input, cap: cap, reasons: &reasons)
                return DispatchAdvice(verdict: .runtime(decisive.runtime), confidence: .high,
                                      reasons: reasons, fanOut: fan,
                                      tokenMultiplier: fan > 1 ? Double(fan) : nil,
                                      waitUntil: nil)
            }
        }

        // 2 — Budget. With no history, headroom is the only honest tie-breaker
        // between two runtimes that can both do the work.
        let usable = input.budgets.filter { $0.runtime.usesTranscript && !$0.exhausted }
        guard !usable.isEmpty else {
            let soonest = input.budgets.compactMap(\.resetsAt).min()
            reasons.append("every runtime is out of window")
            return DispatchAdvice(verdict: .abstain, confidence: .high, reasons: reasons,
                                  fanOut: 0, tokenMultiplier: nil, waitUntil: soonest)
        }

        let ranked = usable.sorted { $0.headroomPercent > $1.headroomPercent }
        guard let best = ranked.first else {
            return DispatchAdvice(verdict: .abstain, confidence: .low, reasons: reasons,
                                  fanOut: 0, tokenMultiplier: nil, waitUntil: nil)
        }

        // A near-tie is not a decision. Kind cannot break it either: there is no
        // evidence that research suits one runtime over the other, and inventing
        // that preference would be exactly the weak guess abstention exists for.
        if ranked.count > 1, best.headroomPercent - ranked[1].headroomPercent < 10 {
            reasons.append("both runtimes have similar headroom"
                           + " (\(Int(best.headroomPercent))% vs \(Int(ranked[1].headroomPercent))%),"
                           + " and nothing else distinguishes them for this task")
            return DispatchAdvice(verdict: .abstain, confidence: .medium, reasons: reasons,
                                  fanOut: 0, tokenMultiplier: nil, waitUntil: nil)
        }

        reasons.append("\(best.runtime.shortLabel) has the most headroom (\(Int(best.headroomPercent))% left)")
        let fan = fanOut(input, cap: cap, reasons: &reasons)
        return DispatchAdvice(verdict: .runtime(best.runtime), confidence: .medium,
                              reasons: reasons, fanOut: fan,
                              tokenMultiplier: fan > 1 ? Double(fan) : nil, waitUntil: nil)
    }

    // MARK: - Capability

    private static func capabilityDecision(_ input: DispatchInputs) -> (runtime: AgentRuntime, reason: String)? {
        let wanted = requiredCapabilities(of: input.task)
        guard !wanted.isEmpty else { return nil }

        var holders: [AgentRuntime: [String]] = [:]
        for (runtime, inventory) in input.capabilities where runtime.usesTranscript {
            let owned = Set(inventory.skills + inventory.mcpServers).map { $0.lowercased() }
            let matched = wanted.filter { needed in owned.contains { $0.contains(needed) } }
            if !matched.isEmpty { holders[runtime] = matched }
        }
        // Decisive only when exactly one runtime can do it. Two holders is not a
        // signal, it is a tie.
        guard holders.count == 1, let (runtime, matched) = holders.first else { return nil }
        return (runtime, "only \(runtime.shortLabel) has \(matched.sorted().joined(separator: ", ")) in this repo")
    }

    /// Capability names the task asks for, taken from its title. Crude on purpose:
    /// a wrong match costs a recommendation the user can override, and inferring
    /// more would mean guessing.
    private static func requiredCapabilities(of task: PlanTask) -> [String] {
        let text = task.title.lowercased()
        return text
            .split(whereSeparator: { !$0.isLetter && $0 != "-" })
            .map(String.init)
            .filter { $0.count >= 4 }
    }

    private static func budget(for runtime: AgentRuntime, in input: DispatchInputs) -> RuntimeBudget? {
        input.budgets.first { $0.runtime == runtime }
    }

    // MARK: - Concurrency, measured

    /// How many more sessions this machine can take. Derived from what a session
    /// costs *here* — Throttle already watches those processes — and from macOS's
    /// own pressure level, which outranks any arithmetic on free bytes.
    ///
    /// Nothing about this is configurable, and deliberately so: a threshold tuned
    /// on the developer's Mac would be wrong on every machine Throttle is sold to.
    static func concurrencyCap(memory: MemoryHealth) -> ConcurrencyCap {
        guard memory.totalBytes > 0 else {
            return ConcurrencyCap(additionalSessions: 1,
                                  reason: "memory not sampled yet — staying conservative",
                                  measuredPerSessionBytes: nil)
        }
        if memory.critical {
            return ConcurrencyCap(additionalSessions: 0,
                                  reason: "the machine is already under critical memory pressure",
                                  measuredPerSessionBytes: measuredFootprint(memory))
        }

        let measured = measuredFootprint(memory)
        let perSession = measured ?? unmeasuredSessionBytes
        let margin = UInt64(Double(memory.totalBytes) * safetyMarginFraction)
        let free = memory.totalBytes > memory.usedBytes + margin
            ? memory.totalBytes - memory.usedBytes - margin
            : 0
        var slots = perSession > 0 ? Int(free / perSession) : 0

        if memory.underPressure { slots = min(slots, 1) }

        let footprint = measured.map { "\($0 / 1_000_000_000) GB per observed session" }
            ?? "no session observed yet, assuming a conservative footprint"
        return ConcurrencyCap(additionalSessions: slots,
                              reason: "\(slots) more session(s) fit — \(footprint)",
                              measuredPerSessionBytes: measured)
    }

    private static func measuredFootprint(_ memory: MemoryHealth) -> UInt64? {
        guard memory.claudeCount > 0, memory.claudeRSSBytes > 0 else { return nil }
        return memory.claudeRSSBytes / UInt64(memory.claudeCount)
    }

    // MARK: - Fan-out

    /// Fan-out is bounded by two things only: what the user allowed this task to
    /// cost, and what the machine measurably has room for. No arbitrary ceiling.
    private static func fanOut(_ input: DispatchInputs, cap: ConcurrencyCap,
                               reasons: inout [String]) -> Int {
        guard input.task.kind == .research else { return 1 }

        guard input.estimatedAgentCostEUR > 0 else { return 1 }
        let affordable = Int(input.spendCapEUR / input.estimatedAgentCostEUR)
        guard affordable > 1 else {
            reasons.append("one agent — the spend cap covers a single run of this task")
            return 1
        }
        let allowed = max(1, min(affordable, cap.additionalSessions))
        if allowed > 1 {
            reasons.append("research task: \(allowed) agents, ≈\(allowed)× the tokens of one — \(cap.reason)")
        } else {
            reasons.append("one agent — \(cap.reason)")
        }
        return allowed
    }
}
