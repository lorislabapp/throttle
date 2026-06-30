import XCTest
@testable import Throttle

/// DeltaMem residual-tree store: roots + scope-applicable deltas compose into one
/// effective fact, deltas never orphan, and the graph persists.
final class DeltaMemStoreTests: XCTestCase {

    private var tmp: URL!
    private var saved: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dm-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        saved = DeltaMemStore.baseDir
        DeltaMemStore.baseDir = tmp
    }
    override func tearDownWithError() throws {
        DeltaMemStore.baseDir = saved
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_addRoot_resolvesBareBody() {
        let r = DeltaMemStore.addRoot(title: "Stripe API", body: "Use the REST API with a secret key.")
        XCTAssertEqual(DeltaMemStore.resolve(rootId: r.id, scope: "Throttle"), "Use the REST API with a secret key.")
    }

    func test_delta_appliesOnlyToMatchingScope() {
        let r = DeltaMemStore.addRoot(title: "Stripe API", body: "General Stripe usage.")
        DeltaMemStore.addDelta(rootId: r.id, scope: "Throttle", body: "Pin apiVersion 2024-11-20.acacia.")

        let inScope = DeltaMemStore.resolve(rootId: r.id, scope: "Throttle")!
        XCTAssertTrue(inScope.contains("General Stripe usage."))
        XCTAssertTrue(inScope.contains("Pin apiVersion 2024-11-20.acacia."))

        let outScope = DeltaMemStore.resolve(rootId: r.id, scope: "Clasp")!
        XCTAssertFalse(outScope.contains("acacia"), "delta must not leak into an unrelated scope")
    }

    func test_globalDelta_appliesEverywhere() {
        let r = DeltaMemStore.addRoot(title: "Coding", body: "Write clean code.")
        DeltaMemStore.addDelta(rootId: r.id, scope: "", body: "Always add tests.")
        XCTAssertTrue(DeltaMemStore.resolve(rootId: r.id, scope: "anything")!.contains("Always add tests."))
    }

    func test_addDelta_toUnknownRoot_isRejected() {
        XCTAssertNil(DeltaMemStore.addDelta(rootId: "nope", scope: "x", body: "y"))
    }

    func test_findRoot_caseInsensitive() {
        let r = DeltaMemStore.addRoot(title: "Stripe API", body: "x")
        XCTAssertEqual(DeltaMemStore.findRoot(matching: "stripe")?.id, r.id)
    }

    func test_persistsAcrossLoad() {
        let r = DeltaMemStore.addRoot(title: "Persisted", body: "kept")
        XCTAssertEqual(DeltaMemStore.load().roots.first?.id, r.id)
    }
}
