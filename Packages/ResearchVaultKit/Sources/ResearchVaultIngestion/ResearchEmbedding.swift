import Foundation
import NaturalLanguage

public protocol ResearchEmbeddingProvider {
    var identifier: String { get }
    var dimension: Int { get }
    func embed(_ text: String) -> [Float]?
}

public struct NLEmbeddingResearchProvider: ResearchEmbeddingProvider {
    private let model: NLEmbedding?
    public let identifier: String

    public init(language: NLLanguage = .english) {
        model = NLEmbedding.sentenceEmbedding(for: language)
        identifier = "apple-nlembedding-sentence-" + language.rawValue
    }

    public var dimension: Int { model?.dimension ?? 0 }

    public func embed(_ text: String) -> [Float]? {
        let bounded = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8_192))
        guard !bounded.isEmpty, let vector = model?.vector(for: bounded) else { return nil }
        return vector.map(Float.init)
    }
}

public enum ResearchVectorBackend: String, Codable, CaseIterable, Sendable {
    case exactSwift = "exact-swift-cosine"
    case sqliteVec = "sqlite-vec"
    case sqliteVec1 = "sqlite-vec1"
}

public struct ResearchVectorBackendEvidence: Codable, Equatable, Sendable {
    public let backend: ResearchVectorBackend
    public let available: Bool
    public let reason: String

    public init(backend: ResearchVectorBackend, available: Bool, reason: String) {
        self.backend = backend
        self.available = available
        self.reason = reason
    }

    public static let currentBuild = [
        ResearchVectorBackendEvidence(
            backend: .exactSwift,
            available: true,
            reason: "dependency-free exact challenger"
        ),
        ResearchVectorBackendEvidence(
            backend: .sqliteVec,
            available: false,
            reason: "not linked into the single SQLCipher core"
        ),
        ResearchVectorBackendEvidence(
            backend: .sqliteVec1,
            available: false,
            reason: "extension not bundled or distribution-qualified"
        ),
    ]
}

public struct ResearchVectorRecord: Equatable, Sendable {
    public let documentID: String
    public let vector: [Float]

    public init(documentID: String, vector: [Float]) {
        self.documentID = documentID
        self.vector = vector
    }
}

public struct ResearchVectorHit: Equatable, Sendable {
    public let documentID: String
    public let score: Float
}

public struct ExactCosineResearchIndex: Sendable {
    private var records: [String: [Float]] = [:]

    public init() {}

    public var count: Int { records.count }

    public mutating func upsert(_ record: ResearchVectorRecord) {
        guard !record.documentID.isEmpty, !record.vector.isEmpty else { return }
        records[record.documentID] = record.vector
    }

    public func search(vector: [Float], limit: Int) -> [ResearchVectorHit] {
        guard !vector.isEmpty, limit > 0, let queryNorm = norm(vector) else { return [] }
        return records.compactMap { documentID, candidate -> ResearchVectorHit? in
            guard candidate.count == vector.count, let candidateNorm = norm(candidate) else { return nil }
            let score = zip(vector, candidate).reduce(Float.zero) { $0 + $1.0 * $1.1 }
                / (queryNorm * candidateNorm)
            guard score.isFinite else { return nil }
            return ResearchVectorHit(documentID: documentID, score: score)
        }
        .sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.documentID < rhs.documentID : lhs.score > rhs.score
        }
        .prefix(limit)
        .map { $0 }
    }

    private func norm(_ vector: [Float]) -> Float? {
        let value = vector.reduce(Float.zero) { $0 + $1 * $1 }.squareRoot()
        return value > 0 && value.isFinite ? value : nil
    }
}

public enum ReciprocalRankFusion {
    public static func rank(
        rankings: [[String]],
        limit: Int,
        constant: Double = 60
    ) -> [String] {
        guard limit > 0, constant > 0 else { return [] }
        var scores: [String: Double] = [:]
        for ranking in rankings {
            var seen = Set<String>()
            for (offset, documentID) in ranking.enumerated() where seen.insert(documentID).inserted {
                scores[documentID, default: 0] += 1 / (constant + Double(offset + 1))
            }
        }
        return scores.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        .prefix(limit)
        .map(\.key)
    }
}
