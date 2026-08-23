import Foundation

enum ModelTier: String, CaseIterable, Codable, Sendable {
    case fable
    case opus
    case sonnet
    case haiku
    case other

    /// Buckets follow `ModelPricing.bucket(forModel:)` so the Swift enum and the
    /// SQL `CASE` cannot disagree.
    ///
    /// `fable` was missing here while the SQL already had it, so every Fable
    /// event arrived in the UI as `.other` and was priced at the Sonnet rate —
    /// understated 3.3× in the model-split chart and in the plan advice, on an
    /// account where Fable is the second-largest tier.
    static func from(modelString: String) -> ModelTier {
        ModelTier(rawValue: ModelPricing.bucket(forModel: modelString)) ?? .other
    }
}
