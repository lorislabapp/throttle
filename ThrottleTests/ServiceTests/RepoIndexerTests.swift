import XCTest
@testable import Throttle

/// Repo ingestion: eligibility (extensions, excluded dirs, size), incremental
/// manifest (unchanged skip, changed re-embed, deleted evict), removeDoc, and
/// per-repo corpus persistence. Deterministic stub embedder — no NL model needed.
final class RepoIndexerTests: XCTestCase {

    private struct StubEmbedder: EmbeddingProvider {
        var dimension: Int { 16 }
        func embed(_ text: String) -> [Float]? {
            var v = [Float](repeating: 0, count: 16)
            for w in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
                v[w.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 16] += 1
            }
            return v.allSatisfy { $0 == 0 } ? nil : v
        }
    }

    private var repo: URL!
    override func setUpWithError() throws {
        repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: repo) }

    private func write(_ rel: String, _ contents: String) throws {
        let url = repo.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func test_indexes_eligibleFiles_skipsExcludedAndBinary() throws {
        try write("a.swift", "func alpha() {}")
        try write("README.md", "alpha project docs")
        try write("node_modules/lib.js", "should be excluded")     // excluded dir
        try write("image.png", "not really text but png ext")       // ext not allowed
        var idx = SemanticIndex(embedder: StubEmbedder())
        var manifest: [String: String] = [:]

        let s = RepoIndexer.indexDirectory(repo, into: &idx, manifest: &manifest)
        XCTAssertEqual(s.scanned, 2, "only a.swift + README.md are eligible")
        XCTAssertEqual(s.indexed, 2)
        XCTAssertEqual(Set(manifest.keys), ["a.swift", "README.md"])
    }

    func test_incremental_skipsUnchanged_reembedsChanged() throws {
        try write("a.swift", "func alpha() {}")
        var idx = SemanticIndex(embedder: StubEmbedder())
        var manifest: [String: String] = [:]
        _ = RepoIndexer.indexDirectory(repo, into: &idx, manifest: &manifest)

        let s2 = RepoIndexer.indexDirectory(repo, into: &idx, manifest: &manifest)
        XCTAssertEqual(s2.unchanged, 1)
        XCTAssertEqual(s2.indexed, 0, "nothing changed → no re-embed")

        try write("a.swift", "func beta() {}")
        let s3 = RepoIndexer.indexDirectory(repo, into: &idx, manifest: &manifest)
        XCTAssertEqual(s3.indexed, 1, "content changed → re-embed")
    }

    func test_deletedFile_isEvicted() throws {
        try write("a.swift", "func alpha() {}")
        try write("b.swift", "func beta() {}")
        var idx = SemanticIndex(embedder: StubEmbedder())
        var manifest: [String: String] = [:]
        _ = RepoIndexer.indexDirectory(repo, into: &idx, manifest: &manifest)

        try FileManager.default.removeItem(at: repo.appendingPathComponent("b.swift"))
        let s = RepoIndexer.indexDirectory(repo, into: &idx, manifest: &manifest)
        XCTAssertEqual(s.removed, 1)
        XCTAssertNil(manifest["b.swift"])
        XCTAssertTrue(idx.search("beta", k: 5).allSatisfy { $0.metadata["doc"] != "b.swift" })
    }

    func test_reindex_evictsStaleChunksFromShrunkFile() throws {
        // A long multi-chunk file → then shrink it; old chunk ids must not linger.
        try write("big.md", String(repeating: "alpha\n\n", count: 50))
        var idx = SemanticIndex(embedder: StubEmbedder())
        var manifest: [String: String] = [:]
        _ = RepoIndexer.indexDirectory(repo, into: &idx, manifest: &manifest, maxChars: 10)
        let before = idx.chunkCount
        XCTAssertGreaterThan(before, 1)

        try write("big.md", "alpha")
        _ = RepoIndexer.indexDirectory(repo, into: &idx, manifest: &manifest, maxChars: 10)
        XCTAssertEqual(idx.chunkCount, 1, "shrunk file leaves exactly its new chunk count")
    }

    func test_corpusStore_persistAndLoad() throws {
        let saved = SemanticCorpusStore.baseDir
        SemanticCorpusStore.baseDir = repo.appendingPathComponent("corpus")
        defer { SemanticCorpusStore.baseDir = saved }

        var idx = SemanticIndex(embedder: StubEmbedder())
        idx.index(docId: "x.swift", text: "alpha beta", metadata: ["repo": "R"], maxChars: 100)
        try SemanticCorpusStore.save(repo: "/tmp/fakeRepo", index: idx, manifest: ["x.swift": "h"])

        let reloaded = SemanticCorpusStore.loadIndex(repo: "/tmp/fakeRepo", embedder: StubEmbedder())
        XCTAssertEqual(reloaded.chunkCount, 1)
        XCTAssertEqual(SemanticCorpusStore.loadManifest(repo: "/tmp/fakeRepo"), ["x.swift": "h"])
        XCTAssertEqual(reloaded.search("alpha", k: 1).first?.metadata["doc"], "x.swift")
    }
}
