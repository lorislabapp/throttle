import Foundation

enum ModelTier: String, CaseIterable, Codable, Sendable {
    case opus
    case sonnet
    case haiku
    case other

    static func from(modelString: String) -> ModelTier {
        let lower = modelString.lowercased()
        if lower.contains("opus") { return .opus }
        if lower.contains("sonnet") { return .sonnet }
        if lower.contains("haiku") { return .haiku }
        return .other
    }
}
