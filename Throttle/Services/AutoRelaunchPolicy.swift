import Foundation

/// Decides whether a rejected task may be picked up again automatically.
///
/// This is the one place in Throttle where a session starts without a human
/// gesture, so the gate is a spend limit the user set, not a judgement call. Pure
/// and separate from the UI precisely so that rule is readable and testable.
enum AutoRelaunchPolicy {

    struct Decision: Sendable, Equatable {
        let relaunch: Bool
        let reason: String
    }

    /// `attemptsSoFar` is counted from the log — the number of agents that have
    /// already held this task — so the spend estimate reflects what was really
    /// spent, not what was planned.
    static func decide(state: TaskState, attemptsSoFar: Int,
                       spendCapEUR: Double, estimatedAgentCostEUR: Double) -> Decision {
        guard state.rejectionCount > 0 else {
            return Decision(relaunch: false, reason: "nothing was rejected")
        }
        guard state.status == .pending else {
            return Decision(relaunch: false, reason: "task is \(state.status.rawValue)")
        }
        guard state.owner == nil else {
            return Decision(relaunch: false, reason: "someone already picked it up")
        }
        guard state.rejectionCount < PlanProjection.maxRejections else {
            return Decision(relaunch: false, reason: "the retry ceiling is reached")
        }
        guard estimatedAgentCostEUR > 0 else {
            return Decision(relaunch: false,
                            reason: "no cost estimate yet — not spending blind")
        }
        let spent = Double(attemptsSoFar) * estimatedAgentCostEUR
        guard spent + estimatedAgentCostEUR <= spendCapEUR else {
            return Decision(relaunch: false,
                            reason: String(format: "another attempt would pass the €%.2f cap for this task",
                                           spendCapEUR))
        }
        return Decision(relaunch: true,
                        reason: "rejected \(state.rejectionCount)× and still within the spend cap")
    }
}
