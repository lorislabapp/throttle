import XCTest
@testable import Throttle

/// Edge vector store baseline: exact cosine ranking, id-dedup upsert, k-limit,
/// dim-mismatch safety, Codable persistence. The on-device embedding provider is
/// exercised best-effort (skips if the NL asset isn't on the host).
final class VectorStoreTests: XCTestCase {

    func test_search_ranksByCosineSimilarity() {
        var s = BruteForceVectorStore()
        s.upsert(VectorRecord(id: "x", vector: [1, 0, 0], text: "x-axis"))
        s.upsert(VectorRecord(id: "y", vector: [0, 1, 0], text: "y-axis"))
        s.upsert(VectorRecord(id: "xy", vector: [1, 1, 0], text: "diagonal"))

        let hits = s.search([1, 0, 0], k: 3)
        XCTAssertEqual(hits.first?.id, "x", "identical direction ranks first")
        XCTAssertEqual(hits.map(\.id), ["x", "xy", "y"], "then the 45° diagonal, then orthogonal")
        XCTAssertEqual(hits.first!.score, 1.0, accuracy: 1e-5)
    }

    func test_upsert_dedupesById() {
        var s = BruteForceVectorStore()
        s.upsert(VectorRecord(id: "a", vector: [1, 0], text: "first"))
        s.upsert(VectorRecord(id: "a", vector: [0, 1], text: "second"))
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.search([0, 1], k: 1).first?.text, "second", "upsert replaces by id")
    }

    func test_search_respectsK_andSkipsDimMismatch() {
        var s = BruteForceVectorStore()
        s.upsert(VectorRecord(id: "a", vector: [1, 0, 0]))
        s.upsert(VectorRecord(id: "b", vector: [0.9, 0.1, 0]))
        s.upsert(VectorRecord(id: "wrongdim", vector: [1, 0]))   // 2-d vs 3-d query → skipped
        let hits = s.search([1, 0, 0], k: 1)
        XCTAssertEqual(hits.count, 1)
        XCTAssertFalse(hits.contains { $0.id == "wrongdim" })
    }

    func test_search_emptyQueryOrZeroVector() {
        var s = BruteForceVectorStore()
        s.upsert(VectorRecord(id: "a", vector: [0, 0, 0]))       // zero vector → no NaN, skipped
        XCTAssertTrue(s.search([], k: 3).isEmpty)
        XCTAssertTrue(s.search([1, 0, 0], k: 3).isEmpty, "zero-norm record yields no hit")
    }

    func test_persistence_roundTrip() throws {
        var s = BruteForceVectorStore()
        s.upsert(VectorRecord(id: "a", vector: [0.1, 0.2, 0.3], text: "t", metadata: ["repo": "Throttle"]))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vec-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try s.save(to: url)
        XCTAssertEqual(BruteForceVectorStore.load(from: url), s)
    }

    // MARK: - On-device embeddings (best-effort; skip if unavailable)

    func test_nlEmbedding_similarTextRanksHigher() throws {
        let p = NLEmbeddingProvider()
        try XCTSkipUnless(p.isAvailable, "NLEmbedding sentence model not present on this host")
        guard let qv = p.embed("the cat sat on the mat"),
              let near = p.embed("a kitten rested on the rug"),
              let far = p.embed("quarterly tax accounting spreadsheet") else {
            throw XCTSkip("embedding returned nil")
        }
        var s = BruteForceVectorStore()
        s.upsert(VectorRecord(id: "near", vector: near, text: "near"))
        s.upsert(VectorRecord(id: "far", vector: far, text: "far"))
        XCTAssertEqual(s.search(qv, k: 2).first?.id, "near", "semantically closer text ranks first")
    }
}
