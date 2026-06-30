import XCTest
@testable import Throttle

/// ContentStore (CMV blob store) + end-to-end reversibility of the trimmer's
/// SHA-256 pointers: a trimmed payload must rehydrate to byte-identical original.
final class ContentStoreTests: XCTestCase {

    private var tmp: URL!
    private var savedBase: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cs-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        savedBase = ContentStore.baseDir
        ContentStore.baseDir = tmp.appendingPathComponent("store", isDirectory: true)
    }

    override func tearDownWithError() throws {
        ContentStore.baseDir = savedBase
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Store primitives

    func test_put_get_roundtrip() {
        let data = Data("hello world payload".utf8)
        let hash = ContentStore.put(data)
        XCTAssertEqual(hash.count, 64)
        XCTAssertEqual(ContentStore.get(hash), data)
    }

    func test_put_isContentAddressedAndIdempotent() {
        let a = ContentStore.put(Data("same".utf8))
        let b = ContentStore.put(Data("same".utf8))
        XCTAssertEqual(a, b, "identical bytes → same hash (dedup)")
        let files = try? FileManager.default.contentsOfDirectory(atPath: ContentStore.baseDir.path)
        XCTAssertEqual(files?.filter { $0.hasSuffix(".blob") }.count, 1, "written once")
    }

    func test_get_rejectsMalformedHash() {
        XCTAssertNil(ContentStore.get("not-a-hash"))
        XCTAssertNil(ContentStore.get(String(repeating: "z", count: 64)))
    }

    func test_get_nilForUnknown() {
        XCTAssertNil(ContentStore.get(String(repeating: "a", count: 64)))
    }

    // MARK: - End-to-end: trim writes an expandable pointer

    func test_trimSnapshot_imagePointerRehydrates() throws {
        let b64 = String(repeating: "QUJDREVG", count: 64)   // arbitrary long base64-ish blob
        let line = #"{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(b64)"}}]}}"#
        let session = tmp.appendingPathComponent("11112222.jsonl")
        try (line + "\n").write(to: session, atomically: true, encoding: .utf8)

        let (snapURL, plan) = try ContextTrimmerService.writeSnapshot(session, options: .safe)
        XCTAssertEqual(plan.imagesTrimmed, 1)

        let snap = try String(contentsOf: snapURL, encoding: .utf8)
        XCTAssertFalse(snap.contains(b64), "base64 must be gone from the trimmed transcript")
        XCTAssertTrue(snap.contains("throttle_expand_pointer(hash:"), "pointer carries the rehydrate hash")

        // Extract the hash and confirm the store rehydrates the exact original.
        let hash = try XCTUnwrap(snap.range(of: #"[0-9a-f]{64}"#, options: .regularExpression)
            .map { String(snap[$0]) })
        let restored = try XCTUnwrap(ContentStore.get(hash))
        XCTAssertEqual(String(data: restored, encoding: .utf8), b64, "rehydrates to original base64")
    }

    func test_preview_persistsNothing() throws {
        let b64 = String(repeating: "QUJDREVG", count: 64)
        let line = #"{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(b64)"}}]}}"#
        let session = tmp.appendingPathComponent("33334444.jsonl")
        try (line + "\n").write(to: session, atomically: true, encoding: .utf8)

        let plan = try ContextTrimmerService.preview(session, options: .safe)
        XCTAssertEqual(plan.imagesTrimmed, 1, "preview still counts the trim")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: ContentStore.baseDir.path)) ?? []
        XCTAssertTrue(files.filter { $0.hasSuffix(".blob") }.isEmpty, "read-only preview writes no blobs")
    }
}
