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

    func test_put_get_roundtrip() throws {
        let data = Data("hello world payload".utf8)
        // `put` now returns nil when the bytes did not land, so a successful
        // store must be unwrapped rather than assumed.
        let hash = try XCTUnwrap(ContentStore.put(data))
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
        XCTAssertTrue(snap.contains("throttle_expand_pointer(throttle_id:"), "pointer carries the rehydrate ID")

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

    func test_cmvThreePass_preservesDependenciesAndRehydratesRawToolOutput() throws {
        let output = String(repeating: "mechanical compiler output ", count: 80)
        let toolUse = #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-42","name":"Bash","input":{"command":"swift test"}}]}}"#
        let toolResult = #"{"type":"user","uuid":"u1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-42","content":"\#(output)"}]}}"#
        let session = tmp.appendingPathComponent("55556666.jsonl")
        try ([toolUse, toolResult].joined(separator: "\n") + "\n")
            .write(to: session, atomically: true, encoding: .utf8)

        let (snapURL, plan) = try ContextTrimmerService.writeSnapshot(session, options: .aggressive)
        XCTAssertEqual(plan.toolResultsStubbed, 1)

        let snap = try String(contentsOf: snapURL, encoding: .utf8)
        XCTAssertTrue(snap.contains(#""id":"tool-42""#))
        XCTAssertTrue(snap.contains(#""tool_use_id":"tool-42""#))
        XCTAssertTrue(snap.contains("throttle_expand_pointer(throttle_id:"))
        let throttleID = try XCTUnwrap(snap.range(of: #"[0-9a-f]{64}"#, options: .regularExpression)
            .map { String(snap[$0]) })
        XCTAssertEqual(String(data: try XCTUnwrap(ContentStore.get(throttleID)), encoding: .utf8),
                       output)
    }

    func test_cmvThreePass_stripsOnlySupersededPreCompactionProse() throws {
        let old = String(repeating: "obsolete context ", count: 80)
        let kept = "preserved decision"
        let oldLine = #"{"type":"assistant","uuid":"old","message":{"role":"assistant","content":[{"type":"text","text":"\#(old)"}]}}"#
        let keptLine = #"{"type":"assistant","uuid":"kept","message":{"role":"assistant","content":[{"type":"text","text":"\#(kept)"}]}}"#
        let boundary = #"{"type":"system","uuid":"compact","compactMetadata":{"preservedMessages":{"allUuids":["kept"]}}}"#
        let current = #"{"type":"assistant","uuid":"current","message":{"role":"assistant","content":[{"type":"text","text":"current context"}]}}"#
        let session = tmp.appendingPathComponent("77778888.jsonl")
        try ([oldLine, keptLine, boundary, current].joined(separator: "\n") + "\n")
            .write(to: session, atomically: true, encoding: .utf8)

        let (snapURL, plan) = try ContextTrimmerService.writeSnapshot(session, options: .aggressive)
        XCTAssertEqual(plan.supersededEventsTrimmed, 1)
        let snap = try String(contentsOf: snapURL, encoding: .utf8)
        XCTAssertFalse(snap.contains(old))
        XCTAssertTrue(snap.contains(kept))
        XCTAssertTrue(snap.contains("current context"))
    }
}
