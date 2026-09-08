import CryptoKit
import Foundation
@testable import ThrottleShared
import XCTest

private final class ReturnProtocol: URLProtocol, @unchecked Sendable {
    static let payload = Data(repeating: 65, count: 131_089)
    static let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Length": String(Self.payload.count), "X-Throttle-SHA256": Self.hash
              ]) else { return }
        var payload = Self.payload
        switch request.value(forHTTPHeaderField: "Authorization") {
        case "Bearer truncated": payload.removeLast()
        case "Bearer oversized": payload.append(66)
        case "Bearer corrupt": payload[payload.count - 1] = 66
        default: break
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class EdgeTransferDownloadTests: XCTestCase {
    func testCompleteStreamingDownloadAndThreeDamagedResponses() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReturnProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let id = UUID().uuidString.lowercased()
        let input = EdgeTransferService.Input(id: id, runtime: "codex", nativeSessionID: id,
            sourceCwd: "/local", remoteCwd: "/remote", filename: "fixture.jsonl",
            baselineSHA256: ReturnProtocol.hash, project: "Fixture")
        let expected = EdgeTransferService.Artifact(bytes: ReturnProtocol.payload.count, sha256: ReturnProtocol.hash)
        for scenario in ["valid", "truncated", "oversized", "corrupt"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("return-test-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let connection = EdgeTransferService.Connection(endpoint: "https://fixture.invalid", token: scenario,
                                                            serverID: UUID().uuidString)
            do {
                let file = try await EdgeTransferService.download(input, kind: "transcript", expected: expected,
                    directory: directory, using: connection, session: session)
                XCTAssertEqual(scenario, "valid")
                XCTAssertEqual(try Data(contentsOf: file), ReturnProtocol.payload)
            } catch {
                XCTAssertNotEqual(scenario, "valid", String(describing: error))
                let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
                XCTAssertTrue(files.isEmpty, "An incomplete response must not leave a returned artifact")
            }
        }
    }

    func testManifestRejectsWrongTransferAndInvalidOrOversizedArtifacts() throws {
        let id = UUID().uuidString.lowercased()
        let artifact = EdgeTransferService.Artifact(bytes: 100, sha256: String(repeating: "a", count: 64))
        let valid = EdgeTransferService.FrozenManifest(
            attempt: "return-\(UUID())", transcript: artifact, repo: artifact,
            tree: String(repeating: "b", count: 40), commit: String(repeating: "c", count: 40),
            ref: "refs/throttle/transfers/\(id)/return")
        XCTAssertNoThrow(try valid.validate(id: id))
        XCTAssertThrowsError(try valid.validate(id: UUID().uuidString.lowercased()))
        for count in [0, -1, 128 * 1024 * 1024 + 1] {
            XCTAssertThrowsError(try EdgeTransferService.Artifact(bytes: count, sha256: artifact.sha256).validate())
        }
        XCTAssertThrowsError(try EdgeTransferService.Artifact(bytes: 10, sha256: "unknown").validate())
    }
}
