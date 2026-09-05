@testable import Throttle
import XCTest

/// Intercepts the provider's HTTP call so the fail-closed behaviour can be tested
/// without a node on the other end.
private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var body: Data?
    nonisolated(unsafe) static var status = 200

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: Self.status, httpVersion: nil, headerFields: nil
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body = Self.body { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class OllamaEmbeddingProviderTests: XCTestCase {
    private let endpoint = URL(string: "http://127.0.0.1:11434/api/embed")
        ?? URL(fileURLWithPath: "/embed")

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubProtocol.self)
        StubProtocol.status = 200
        StubProtocol.body = nil
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubProtocol.self)
        super.tearDown()
    }

    private func reply(_ rows: [[Double]]) {
        StubProtocol.body = try? JSONSerialization.data(withJSONObject: ["embeddings": rows])
    }

    func testVectorsOfTheExpectedWidthAreAccepted() async {
        reply([[1, 0, 0, 0], [0, 1, 0, 0]])
        let provider = OllamaEmbeddingProvider(
            endpoint: endpoint, model: "qwen3-embedding:0.6b", expectedDimension: 4
        )
        let vectors = await provider.embed(batch: ["une question", "another question"])
        XCTAssertEqual(vectors.count, 2)
        XCTAssertEqual(vectors[0]?.count, 4)
        XCTAssertEqual(vectors[1]?.count, 4)
    }

    func testAVectorOfTheWrongWidthIsRefusedRatherThanStored() async {
        // A different width means a different model answered. Writing it would put
        // two embedding spaces in one store, where cosine is meaningless and the
        // index ranks nonsense while looking perfectly populated.
        reply([[1, 0, 0, 0], [1, 0, 0]])
        let provider = OllamaEmbeddingProvider(
            endpoint: endpoint, model: "qwen3-embedding:0.6b", expectedDimension: 4
        )
        let vectors = await provider.embed(batch: ["ok", "wrong width"])
        XCTAssertEqual(vectors[0]?.count, 4)
        XCTAssertNil(vectors[1], "a vector from another embedding space must be refused")
    }

    func testAFailedCallYieldsNilRatherThanAPartialBatch() async {
        StubProtocol.status = 500
        let provider = OllamaEmbeddingProvider(
            endpoint: endpoint, model: "qwen3-embedding:0.6b", expectedDimension: 4
        )
        let vectors = await provider.embed(batch: ["a", "b", "c"])
        XCTAssertEqual(vectors.count, 3, "the caller must still get one slot per input")
        XCTAssertTrue(vectors.allSatisfy { $0 == nil })
    }

    func testTheSynchronousPathIsRefusedSoNoCallerBlocksOnTheNetwork() {
        let provider = OllamaEmbeddingProvider(
            endpoint: endpoint, model: "qwen3-embedding:0.6b", expectedDimension: 4
        )
        XCTAssertNil(provider.embed("anything"))
    }

    func testRecordsCarryTheirModelThroughPersistence() throws {
        let record = VectorRecord(
            id: "chunk-1", vector: [0.1, 0.2], text: "t",
            metadata: [:], embedModel: "ollama:qwen3-embedding:0.6b"
        )
        let restored = try JSONDecoder().decode(
            VectorRecord.self, from: JSONEncoder().encode(record)
        )
        XCTAssertEqual(restored.embedModel, "ollama:qwen3-embedding:0.6b")

        // Records written before the field existed decode with nil, which is the
        // signal that their space is unknown and they need re-indexing.
        let legacy = Data(#"{"id":"old","vector":[0.1],"text":"t","metadata":{}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(VectorRecord.self, from: legacy).embedModel)
    }
}
