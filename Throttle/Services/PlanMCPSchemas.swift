import Foundation
import ThrottleMCPContracts

// Compatibility facade. Schema content has one source in the contract package;
// project state and tool advertisement policy remain in the product.
extension PlanMCPTools {
    static func planReadSchema() -> [String: Any] {
        ThrottleMCPSchemas.planReadSchema()
    }

    static func taskClaimSchema() -> [String: Any] {
        ThrottleMCPSchemas.taskClaimSchema()
    }

    static func taskEventSchema() -> [String: Any] {
        ThrottleMCPSchemas.taskEventSchema()
    }

    static func taskVerdictSchema() -> [String: Any] {
        ThrottleMCPSchemas.taskVerdictSchema()
    }

    static func planBootstrapSchema() -> [String: Any] {
        ThrottleMCPSchemas.planBootstrapSchema()
    }

    static func researchRecordSchema() -> [String: Any] {
        ThrottleMCPSchemas.researchRecordSchema()
    }

    static func viabilitySchema() -> [String: Any] {
        ThrottleMCPSchemas.viabilitySchema()
    }

    static var schemas: [[String: Any]] { ThrottleMCPSchemas.planTools }

    static func hasPlan() -> Bool {
        store(nil).planExists()
    }
}
