@testable import Throttle
import XCTest

/// SemanticAutoIndexer gating + incremental drive over multiple repos.
final class SemanticAutoIndexerTests: XCTestCase {

    private struct StubEmbedder: EmbeddingProvider {
        var dimension: Int { 16 }

        /// Named so a record embedded by this stub is never ranked against a
        /// vector from a real model.
        var modelIdentifier: String { "test.stub.16" }
        func embed(_ text: String) -> [Float]? {
            var v = [Float](repeating: 0, count: 16)
            for w in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
                v[w.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 16] += 1
            }
            return v.allSatisfy { $0 == 0 } ? nil : v
        }
    }

    private var tmp: URL!
    private var savedBase: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        savedBase = SemanticCorpusStore.baseDir
        SemanticCorpusStore.baseDir = tmp.appendingPathComponent("corpus")
    }
    override func tearDownWithError() throws {
        SemanticCorpusStore.baseDir = savedBase
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeRepo(_ name: String, file: String, body: String) throws -> String {
        let root = tmp.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try body.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        return root.path
    }

    func test_disabled_skips() throws {
        let r = try makeRepo("a", file: "x.swift", body: "func alpha() {}")
        let s = SemanticAutoIndexer.run(roots: [r], enabled: false, memoryQuiet: false, embedder: StubEmbedder())
        XCTAssertEqual(s.skipped, "disabled")
        XCTAssertEqual(s.filesIndexed, 0)
    }

    func test_memoryPressure_skips() throws {
        let r = try makeRepo("a", file: "x.swift", body: "func alpha() {}")
        let s = SemanticAutoIndexer.run(roots: [r], enabled: true, memoryQuiet: true, embedder: StubEmbedder())
        XCTAssertEqual(s.skipped, "memory-pressure")
        XCTAssertEqual(s.filesIndexed, 0)
    }

    func test_enabled_indexesMultipleRepos_thenIncrementalNoop() throws {
        let r1 = try makeRepo("a", file: "x.swift", body: "func alpha() {}")
        let r2 = try makeRepo("b", file: "y.md", body: "beta docs")
        let s1 = SemanticAutoIndexer.run(roots: [r1, r2], enabled: true, memoryQuiet: false, embedder: StubEmbedder())
        XCTAssertNil(s1.skipped)
        XCTAssertEqual(s1.reposTouched, 2)
        XCTAssertEqual(s1.filesIndexed, 2)

        // Second pass: nothing changed → incremental skips everything.
        let s2 = SemanticAutoIndexer.run(roots: [r1, r2], enabled: true, memoryQuiet: false, embedder: StubEmbedder())
        XCTAssertEqual(s2.reposTouched, 0)
        XCTAssertEqual(s2.filesIndexed, 0)

        // The corpus is queryable.
        let idx = SemanticCorpusStore.loadIndex(repo: r1, embedder: StubEmbedder())
        XCTAssertGreaterThan(idx.chunkCount, 0)
    }

    func test_missingRoot_skippedGracefully() {
        let s = SemanticAutoIndexer.run(roots: ["/nope/does/not/exist"], enabled: true, memoryQuiet: false, embedder: StubEmbedder())
        XCTAssertNil(s.skipped)
        XCTAssertEqual(s.reposTouched, 0)
    }

    // MARK: - Background work: events, skip, pause

    /// Collects events from the @Sendable callback.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [SemanticAutoIndexer.Event] = []
        func add(_ event: SemanticAutoIndexer.Event) { lock.withLock { items.append(event) } }
        var events: [SemanticAutoIndexer.Event] { lock.withLock { items } }
    }

    func test_events_reportTotalAndEachRepo() throws {
        let repoA = try makeRepo("a", file: "x.swift", body: "func alpha() {}")
        let repoB = try makeRepo("b", file: "y.md", body: "beta docs")
        let rec = Recorder()
        _ = SemanticAutoIndexer.run(roots: [repoA, "/nope/missing", repoB], enabled: true, memoryQuiet: false,
                                    embedder: StubEmbedder(), onEvent: { rec.add($0) })
        // The missing root is dropped before the total is announced.
        XCTAssertEqual(rec.events, [
            .started(total: 2),
            .repoStarted(index: 0, name: "a"), .repoFinished(index: 0, name: "a", outcome: .done),
            .repoStarted(index: 1, name: "b"), .repoFinished(index: 1, name: "b", outcome: .done)
        ])
    }

    func test_skip_skipsOnlyCurrentRepo() throws {
        let repoA = try makeRepo("a", file: "x.swift", body: "func alpha() {}")
        let repoB = try makeRepo("b", file: "y.md", body: "beta docs")
        let control = BackgroundWorkControl()
        control.requestSkip()   // consumed by the first repo it interrupts
        let rec = Recorder()
        let summary = SemanticAutoIndexer.run(roots: [repoA, repoB], enabled: true, memoryQuiet: false,
                                        embedder: StubEmbedder(), control: control, onEvent: { rec.add($0) })
        XCTAssertTrue(rec.events.contains(.repoFinished(index: 0, name: "a", outcome: .skipped)))
        XCTAssertTrue(rec.events.contains(.repoFinished(index: 1, name: "b", outcome: .done)))
        XCTAssertEqual(summary.filesIndexed, 1)
        XCTAssertTrue(summary.pausedRemaining.isEmpty)
    }

    func test_pause_stopsAndReportsRemainingRoots() throws {
        let repoA = try makeRepo("a", file: "x.swift", body: "func alpha() {}")
        let repoB = try makeRepo("b", file: "y.md", body: "beta docs")
        let control = BackgroundWorkControl()
        control.requestPause()
        let summary = SemanticAutoIndexer.run(roots: [repoA, repoB], enabled: true, memoryQuiet: false,
                                        embedder: StubEmbedder(), control: control)
        XCTAssertEqual(summary.pausedRemaining, [repoA, repoB])
        XCTAssertEqual(summary.filesIndexed, 0)
    }
}
