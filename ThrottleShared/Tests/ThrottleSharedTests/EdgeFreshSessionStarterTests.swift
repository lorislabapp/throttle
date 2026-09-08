import Foundation
@testable import ThrottleShared
import XCTest

private final class FreshProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        let serverID = UUID().uuidString.lowercased()
        var starts: [String: [String: String]] = [:]
        var attempts = 0
        var loseNextReply = true
        var wrongServer = false
        var invalidStop = false
    }
    static let state = State()
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.state.lock.lock()
        defer { Self.state.lock.unlock() }
        do {
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badURL)
            }
            let state = Self.state
            let body: [String: String]
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                body = try JSONDecoder().decode([String: String].self, from: data)
            } else if let data = request.httpBody {
                body = try JSONDecoder().decode([String: String].self, from: data)
            } else { body = [:] }
            let result: [String: Any]
            if url.path.hasSuffix("capabilities") {
                result = ["contractVersion": 1, "serverID": state.serverID]
            } else if url.path.hasSuffix("stop") {
                let id = body["requestID"] ?? "missing", unit = "throttle-session-\(id).service"
                result = ["contractVersion": 1, "id": id, "serverID": state.serverID, "phase": "stopped",
                          "stopReceipt": ["unit": unit, "controlGroup": "/system.slice/" + unit,
                            "bootID": state.serverID, "invocationID": NSNull(), "activeState": "inactive",
                            "populated": state.invalidStop ? 1 : 0, "observedAt": 1000]]
            } else {
                state.attempts += 1
                let id = body["requestID"] ?? "missing"
                state.starts[id] = body
                if state.loseNextReply {
                    state.loseNextReply = false
                    throw URLError(.networkConnectionLost)
                }
                result = ["id": "fresh-" + id, "serverID": state.wrongServer ? UUID().uuidString : state.serverID,
                          "cwd": body["cwd"] ?? "", "project": body["project"] ?? "",
                          "runtime": body["runtime"] ?? "", "state": "remote"]
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: result))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

final class EdgeFreshSessionStarterTests: XCTestCase {
    func testLostReplyRestartChangedInputsAndVerifiedRecoveryUseOneCreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fresh-start-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FreshProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let first = EdgeFreshSessionStarter(root: root, session: session)
        let endpoint = "https://fixture.invalid"
        do {
            _ = try await first.start(endpoint: endpoint, token: "fixture", cwd: "/repo")
            XCTFail("The reply must be lost after the server accepted the creation")
        } catch {}
        let pending = try await first.pending()
        let saved = try XCTUnwrap(pending)
        let reopened = EdgeFreshSessionStarter(root: root, session: session)
        for (host, cwd, runtime) in [(endpoint, "/other", "claude"), (endpoint, "/repo", "codex"),
                                      ("https://other.invalid", "/repo", "claude")] {
            do {
                _ = try await reopened.start(endpoint: host, token: "fixture", cwd: cwd, runtime: runtime)
                XCTFail("Changed bindings must not start another writer")
            } catch {}
        }
        XCTAssertEqual(FreshProtocol.state.lock.withLock { FreshProtocol.state.attempts }, 1)
        FreshProtocol.state.lock.withLock { FreshProtocol.state.wrongServer = true }
        do { _ = try await reopened.retry(endpoint: endpoint, token: "fixture"); XCTFail("Wrong server") } catch {}
        let retained = try await reopened.pending()
        XCTAssertEqual(retained, saved)
        FreshProtocol.state.lock.withLock { FreshProtocol.state.wrongServer = false }
        let id = try await reopened.retry(endpoint: endpoint, token: "fixture")
        XCTAssertEqual(id, "fresh-" + saved.requestID)
        XCTAssertEqual(FreshProtocol.state.lock.withLock { FreshProtocol.state.starts.count }, 1)
        let resolved = try await reopened.pending()
        XCTAssertNil(resolved)

        FreshProtocol.state.lock.withLock { FreshProtocol.state.loseNextReply = true }
        do {
            _ = try await reopened.start(endpoint: endpoint, token: "fixture", cwd: "/next")
            XCTFail("Reply must be lost")
        } catch {}
        FreshProtocol.state.lock.withLock { FreshProtocol.state.invalidStop = true }
        do {
            try await reopened.stopPending(endpoint: endpoint, token: "fixture")
            XCTFail("Populated scope must retain the request")
        } catch {}
        let stillPending = try await reopened.pending()
        XCTAssertNotNil(stillPending)
        FreshProtocol.state.lock.withLock { FreshProtocol.state.invalidStop = false }
        try await reopened.stopPending(endpoint: endpoint, token: "fixture")
        let stopped = try await reopened.pending()
        XCTAssertNil(stopped)
    }

    func testCorruptDurableRequestFailsClosedAfterReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fresh-corrupt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{partial".utf8).write(to: root.appendingPathComponent("request.json"))
        do {
            _ = try await EdgeFreshSessionStarter(root: root).start(
                endpoint: "https://fixture.invalid", token: "fixture", cwd: "/repo")
            XCTFail("Corrupt state must not contact the server")
        } catch {}
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("request.json"), encoding: .utf8), "{partial")
    }
}
