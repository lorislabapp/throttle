import XCTest
@testable import Throttle

/// OKF v0.1 bundles: serialize↔parse round-trips losslessly and write↔read +
/// search work over the file store.
final class OKFStoreTests: XCTestCase {

    private var tmp: URL!
    private var saved: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("okf-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        saved = OKFStore.baseDir
        OKFStore.baseDir = tmp
    }
    override func tearDownWithError() throws {
        OKFStore.baseDir = saved
        try? FileManager.default.removeItem(at: tmp)
    }

    private func sample() -> OKFBundle {
        OKFBundle(title: "Claude Code Optimization",
                  confidence: "high",
                  tags: ["tokens", "cache"],
                  sources: ["https://example.com/a", "https://example.com/b"],
                  created: Date(timeIntervalSince1970: 1_700_000_000),   // exact second
                  body: "## Findings\n\nCaveman saves 65–75%.\nPrompt cache 41–80%.")
    }

    func test_serialize_parse_roundTrip() throws {
        let b = sample()
        let parsed = try XCTUnwrap(OKFStore.parse(OKFStore.serialize(b)))
        XCTAssertEqual(parsed, b)
    }

    func test_serialize_hasFrontmatter() {
        let s = OKFStore.serialize(sample())
        XCTAssertTrue(s.hasPrefix("---\nokf_version: 0.1\n"))
        XCTAssertTrue(s.contains("tags: [tokens, cache]"))
        XCTAssertTrue(s.contains("  - https://example.com/a"))
    }

    func test_write_read_andList() throws {
        let url = try OKFStore.write(sample())
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".okf.md"))
        XCTAssertEqual(OKFStore.read(url), sample())
        XCTAssertEqual(OKFStore.list().count, 1)
    }

    func test_search_byTitleAndTag() throws {
        _ = try OKFStore.write(sample())
        XCTAssertEqual(OKFStore.search("optimization").count, 1, "matches title")
        XCTAssertEqual(OKFStore.search("CACHE").count, 1, "matches tag, case-insensitive")
        XCTAssertEqual(OKFStore.search("nonexistent").count, 0)
    }

    func test_slug() {
        XCTAssertEqual(OKFStore.slug("Claude Code: Optimization!"), "claude-code-optimization")
        XCTAssertEqual(OKFStore.slug("***"), "bundle")
    }
}
