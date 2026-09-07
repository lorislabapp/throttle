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
    /// Identifies the embedding space, so records can be tagged and a mismatch
    /// detected rather than silently ranked against an incompatible space.
    var modelIdentifier: String { get }
    /// Embed several texts at once.
    ///
    /// A remote provider pays one round trip per call, so embedding a repo one
    /// chunk at a time over the network is far slower than doing it locally —
    /// batching is what makes an off-device provider viable at all, not an
    /// optimisation. Local providers inherit the default, which simply loops.
    func embed(batch texts: [String]) async -> [[Float]?]
}

extension EmbeddingProvider {
    func embed(batch texts: [String]) async -> [[Float]?] {
        texts.map { embed($0) }
    }
}

/// On-device sentence embeddings via NaturalLanguage. `sentenceEmbedding(for:)` may
/// be nil on a host where the asset isn't present — callers must treat embeddings
/// as best-effort (the brute-force store simply has nothing to search until one is
/// available), never as a hard guarantee.
struct NLEmbeddingProvider: EmbeddingProvider {
    private let model: NLEmbedding?
    private let language: NLLanguage

    init(language: NLLanguage = .english) {
        self.language = language
        self.model = NLEmbedding.sentenceEmbedding(for: language)
    }

    var dimension: Int { model?.dimension ?? 0 }

    var isAvailable: Bool { model != nil }

    var modelIdentifier: String { "apple-nlembedding-\(language.rawValue)" }

    func embed(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let v = model?.vector(for: trimmed) else { return nil }
        return v.map(Float.init)   // NLEmbedding yields [Double]
    }
}

/// Embeddings from a private Ollama endpoint — the same node that already serves
/// local delegation, and the same model that embedded the DeepSearsh corpus, so
/// both systems share one vector space instead of two incompatible ones.
///
/// This exists because the on-device path costs what it costs: embedding a whole
/// repo is CPU and RAM heavy on a 16 GB Mac that already swaps, which is exactly
/// why automatic indexing ships disabled. Moving that work to the box with the
/// GPU removes the reason it is off.
///
/// It fails closed. A remote provider that quietly falls back to a different
/// model would write vectors from two spaces into one store, and cosine between
/// them is meaningless — an index that looks populated and ranks nonsense is
/// worse than one that is honestly empty.
struct OllamaEmbeddingProvider: EmbeddingProvider {
    let endpoint: URL
    let model: String
    /// Declared by the model card; verified on the first successful response.
    let expectedDimension: Int

    private static let batchLimit = 32   // measured optimum on the shared node
    private static let maximumCharacters = 2_000

    init(endpoint: URL, model: String, expectedDimension: Int = 1_024) {
        self.endpoint = endpoint
        self.model = model
        self.expectedDimension = expectedDimension
    }

    var dimension: Int { expectedDimension }
    var modelIdentifier: String { "ollama:\(model)" }

    /// Synchronous embedding is not offered: it would mean a blocking network
    /// call per chunk. Callers that only have the sync path get nil and keep
    /// their local provider.
    func embed(_ text: String) -> [Float]? { nil }

    func embed(batch texts: [String]) async -> [[Float]?] {
        var out: [[Float]?] = []
        out.reserveCapacity(texts.count)
        for start in stride(from: 0, to: texts.count, by: Self.batchLimit) {
            let slice = Array(texts[start ..< min(start + Self.batchLimit, texts.count)])
            out.append(contentsOf: await send(slice))
        }
        return out
    }

    private func send(_ texts: [String]) async -> [[Float]?] {
        let trimmed = texts.map { String($0.prefix(Self.maximumCharacters)) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["model": model, "input": trimmed]
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = object["embeddings"] as? [[Double]],
                  rows.count == trimmed.count
            else { return Array(repeating: nil, count: trimmed.count) }

            return rows.map { row in
                // A different width means a different model answered. Refuse it
                // rather than write a vector no query will ever match.
                guard row.count == expectedDimension else { return nil }
                return row.map(Float.init)
            }
        } catch {
            return Array(repeating: nil, count: trimmed.count)
        }
    }
}
