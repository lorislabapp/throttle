import SwiftUI

// The plan-wide "NEXT STEP" banner used to sit above the tree. The inbox's
// NEEDS YOU group now answers that question by structure, so only the naming
// helper the rest of the cockpit shares remains here.
extension PlanTreeView {
    /// "claudeCode" is a storage key; people read "Claude Code".
    static func runtimeName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return AgentRuntime(rawValue: raw)?.label ?? raw
    }
}
