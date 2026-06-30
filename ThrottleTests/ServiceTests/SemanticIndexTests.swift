import XCTest
@testable import Throttle

/// SemanticIndex orchestration: chunking, embed→upsert→query, persistence. Uses a
/// deterministic stub embedder so ranking is host-independent (no NL model needed).
final class SemanticIndexTests: XCTestCase {

    /// Deterministic bag-of-words embedder: each word adds to a fixed bucket.
    /// Similar word sets → similar vectors. No reliance on Swift's randomized
    /// String.hashValue (we sum unicode scalars).
    private struct StubEmbedder: EmbeddingProvider {
        var dimension: Int { 16 }
        func embed(_ text: String) -> [Float]? {
            var v = [Float](repeating: 0, count: 16)
            for w in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
                let bucket = w.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 16
                v[bucket] += 1
            }
            return v
        }
    }

    // MARK: - Chunking

    func test_chunk_packsParagraphsUnderLimit() {
        let text = "para one.\n\npara two.\n\npara three."
        let chunks = SemanticIndex.chunk(text, maxChars: 100)
        XCTAssertEqual(chunks.count, 1, "all three fit in one chunk")
    }

    func test_chunk_splitsWhenOverLimit() {
        let text = "aaaa\n\nbbbb\n\ncccc"   // 4 chars each
        let chunks = SemanticIndex.chunk(text, maxChars: 6)
        XCTAssertEqual(chunks, ["aaaa", "bbbb", "cccc"], "each paragraph its own chunk")
    }

    func test_chunk_hardSplitsOverlongParagraph() {
        let chunks = SemanticIndex.chunk(String(repeating: "x", count: 25), maxChars: 10)
        XCTAssertEqual(chunks.map(\.count), [10, 10, 5])
    }

    func test_chunk_emptyText() {
        XCTAssertTrue(SemanticIndex.chunk("   \n\n  ", maxChars: 10).isEmpty)
    }

    // MARK: - Index + query

    func test_index_countsChunks_andDedupesByDoc() {
        var idx = SemanticIndex(embedder: StubEmbedder())
        let n = idx.index(docId: "d1", text: "alpha\n\nbeta\n\ngamma", maxChars: 6)
        XCTAssertEqual(n, 3)
        XCTAssertEqual(idx.chunkCount, 3)
        // Re-index same doc with fewer chunks → old ones for #0..#2 overwritten/kept by id.
        let n2 = idx.index(docId: "d1", text: "delta", maxChars: 100)
        XCTAssertEqual(n2, 1)
        XCTAssertNotNil(idx.search("delta", k: 1).first)
    }

    func test_search_returnsSemanticallyNearestChunk() {
        var idx = SemanticIndex(embedder: StubEmbedder())
        idx.index(docId: "near", text: "alpha alpha beta", maxChars: 100)
        idx.index(docId: "far",  text: "zeta omega kappa", maxChars: 100)
        let hits = idx.search("alpha beta", k: 2)
        XCTAssertEqual(hits.first?.metadata["doc"], "near", "closest word-set ranks first")
    }

    func test_searchHybrid_keywordFallbackWhenNoEmbedder() {
        // Built with a model; queried later when the model is gone → pure keyword
        // ranking over the stored chunks still finds the exact identifier.
        struct Dead: EmbeddingProvider { var dimension: Int { 0 }; func embed(_ t: String) -> [Float]? { nil } }
        var built = SemanticIndex(embedder: StubEmbedder())
        built.index(docId: "match", text: "func authenticateUser keychain token", maxChars: 100)
        built.index(docId: "other", text: "networking retry backoff timeout", maxChars: 100)
        let queryTime = SemanticIndex(embedder: Dead(), store: built.store)
        let hits = queryTime.searchHybrid("authenticateUser", k: 2)
        XCTAssertEqual(hits.first?.metadata["doc"], "match", "keyword fallback ranks the exact identifier")
    }

    func test_searchHybrid_returnsTopWithEmbedder() {
        var idx = SemanticIndex(embedder: StubEmbedder())
        idx.index(docId: "a", text: "alpha beta gamma", maxChars: 100)
        idx.index(docId: "b", text: "zeta omega kappa", maxChars: 100)
        XCTAssertEqual(idx.searchHybrid("alpha beta", k: 1).first?.metadata["doc"], "a")
    }

    func test_terms_filtersShortTokens() {
        XCTAssertEqual(Set(SemanticIndex.terms("API is ok now now")), ["api", "now"])  // drop <3 + dedup
    }

    func test_search_emptyWhenEmbedderUnavailable() {
        struct Dead: EmbeddingProvider { var dimension: Int { 0 }; func embed(_ t: String) -> [Float]? { nil } }
        var idx = SemanticIndex(embedder: Dead())
        XCTAssertEqual(idx.index(docId: "d", text: "anything", maxChars: 100), 0)
        XCTAssertTrue(idx.search("anything").isEmpty)
    }

    func test_persistence_roundTrip() throws {
        var idx = SemanticIndex(embedder: StubEmbedder())
        idx.index(docId: "d1", text: "alpha beta gamma", maxChars: 100)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("si-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try idx.save(to: url)

        let reloaded = SemanticIndex.load(from: url, embedder: StubEmbedder())
        XCTAssertEqual(reloaded.chunkCount, 1)
        XCTAssertEqual(reloaded.search("alpha", k: 1).first?.metadata["doc"], "d1")
    }
}
