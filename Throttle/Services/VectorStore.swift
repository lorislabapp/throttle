import Foundation

/// Edge vector store (Chantier 4) — the stack-agnostic layer. `VectorStore` is the
/// contract; `BruteForceVectorStore` is the pure-Swift V1 baseline (cosine over
/// Float arrays, Codable persistence) that runs today with zero native deps and
/// zero notarization risk. A sqlite-vec or Wax-backed implementation can drop in
/// behind the same protocol later for scale/ANE acceleration — the roadmap's
/// "ship the baseline, keep the architecture ready" stance.
struct VectorRecord: Codable, Sendable, Equatable {
    let id: String
    var vector: [Float]
    var text: String                    // the chunk text, returned on a hit
    var metadata: [String: String]      // e.g. ["repo": "Throttle", "path": "…"]

    init(id: String, vector: [Float], text: String = "", metadata: [String: String] = [:]) {
        self.id = id; self.vector = vector; self.text = text; self.metadata = metadata
    }
}

struct VectorHit: Sendable, Equatable {
    let id: String
    let score: Float                    // cosine similarity, [-1, 1]
    let text: String
    let metadata: [String: String]
}

protocol VectorStore {
    mutating func upsert(_ record: VectorRecord)
    func search(_ query: [Float], k: Int) -> [VectorHit]
    var count: Int { get }
}

/// Pure-Swift brute-force store. Exact (not approximate) cosine ranking — correct
/// and dependency-free; linear in record count, which is fine at the
/// thousands-of-chunks scale of a local polyrepo on a 16 GB Mac. Upsert dedupes by
/// id. Persists via Codable (JSON: human-diffable; switch to packed Float bytes if
/// size ever bites).
struct BruteForceVectorStore: VectorStore, Codable, Equatable {
    private(set) var records: [String: VectorRecord] = [:]

    var count: Int { records.count }

    mutating func upsert(_ record: VectorRecord) { records[record.id] = record }

    @discardableResult
    mutating func remove(_ id: String) -> Bool { records.removeValue(forKey: id) != nil }

    func search(_ query: [Float], k: Int) -> [VectorHit] {
        guard !query.isEmpty, k > 0 else { return [] }
        let qNorm = norm(query)
        guard qNorm > 0 else { return [] }
        let hits: [VectorHit] = records.values.compactMap { r in
            guard r.vector.count == query.count else { return nil }   // dim mismatch → skip
            let rNorm = norm(r.vector)
            guard rNorm > 0 else { return nil }
            let score = dot(query, r.vector) / (qNorm * rNorm)
            guard !score.isNaN else { return nil }
            return VectorHit(id: r.id, score: score, text: r.text, metadata: r.metadata)
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(k))
    }

    // MARK: - Persistence

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    static func load(from url: URL) -> BruteForceVectorStore {
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(BruteForceVectorStore.self, from: data) else {
            return BruteForceVectorStore()
        }
        return store
    }

    // MARK: - Math

    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0; for i in a.indices { s += a[i] * b[i] }; return s
    }
    private func norm(_ a: [Float]) -> Float {
        var s: Float = 0; for v in a { s += v * v }; return s.squareRoot()
    }
}
