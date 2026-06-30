import Foundation
import NaturalLanguage

/// Embedding source for the edge vector store (Chantier 4). `EmbeddingProvider` is
/// the contract; `NLEmbeddingProvider` is the decision-light V1 — Apple's on-device
/// `NLEmbedding` sentence model. Zero downloads, zero external deps, runs locally.
/// The bge-small / CoreML / MLX-on-ANE path the roadmap eyes for accuracy + speed
/// is a later drop-in behind this same protocol.
protocol EmbeddingProvider {
    /// Embed text into a vector, or nil if the model is unavailable on this host.
    func embed(_ text: String) -> [Float]?
    /// Vector dimension (0 if the model isn't loaded).
    var dimension: Int { get }
}

/// On-device sentence embeddings via NaturalLanguage. `sentenceEmbedding(for:)` may
/// be nil on a host where the asset isn't present — callers must treat embeddings
/// as best-effort (the brute-force store simply has nothing to search until one is
/// available), never as a hard guarantee.
struct NLEmbeddingProvider: EmbeddingProvider {
    private let model: NLEmbedding?

    init(language: NLLanguage = .english) {
        self.model = NLEmbedding.sentenceEmbedding(for: language)
    }

    var dimension: Int { model?.dimension ?? 0 }

    var isAvailable: Bool { model != nil }

    func embed(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let v = model?.vector(for: trimmed) else { return nil }
        return v.map(Float.init)   // NLEmbedding yields [Double]
    }
}
