import Darwin
import Foundation
@testable import Throttle
import XCTest

/// Only bounded synthetic local processes: no MCP configuration, account or API.
final class NotebookLMGatewayProcessTests: XCTestCase {
    func testSilentChildTimesOutAndIsReaped() async throws {
        let fixture = try Fixture(command: "exec /bin/sleep 5")
        defer { fixture.remove() }
        let start = Date()
        do {
            _ = try await fixture.run(timeout: 0.15)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? NotebookLMGatewayClientError, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        try fixture.assertStopped("root")
    }

    func testExitedRootWithDescendantHoldingStdoutDoesNotHang() async throws {
        let fixture = try Fixture(command: "/bin/sleep 5 & echo $! > descendant; exit 0")
        defer { fixture.remove() }
        let start = Date()
        do {
            _ = try await fixture.run(timeout: 0.15)
            XCTFail("Expected timeout while descendant holds pipe")
        } catch {
            XCTAssertEqual(error as? NotebookLMGatewayClientError, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        try fixture.assertStopped("root")
        try fixture.assertStopped("descendant")
    }

    func testTermIgnoringProcessEscalatesWithinBound() async throws {
        let fixture = try Fixture(command: "trap '' TERM; exec /bin/sleep 5")
        defer { fixture.remove() }
        let start = Date()
        do {
            _ = try await fixture.run(timeout: 0.15)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? NotebookLMGatewayClientError, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        try fixture.assertStopped("root")
    }

    func testCancellationStopsOwnedChildWithoutWaitingForStdoutEOF() async throws {
        let fixture = try Fixture(command: "trap '' TERM; exec /bin/sleep 5")
        defer { fixture.remove() }
        let task = Task { try await fixture.run(timeout: 5) }
        try await fixture.awaitStarted()
        let start = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        try fixture.assertStopped("root")
    }

    func testResponseIsFramedAndRequestEOFStillDelivered() async throws {
        let fixture = try Fixture(command:
            "cat >/dev/null; printf '%s\\n' '{\"id\":2,\"result\":{}}'; exec /bin/sleep 5")
        defer { fixture.remove() }
        let data = try await fixture.run(timeout: 1)
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"id":2,"result":{}}"#)
        try fixture.assertStopped("root")
    }
}

private struct Fixture: Sendable {
    let folder: URL
    let script: String

    init(command: String) throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("throttle-nlm-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        script = "cd " + Self.quote(folder.path) + "; echo $$ > root; " + command
    }

    func run(timeout: TimeInterval) async throws -> Data {
        try await NotebookLMGatewayProcess.execute(executable: "/bin/sh", arguments: ["-c", script],
            environment: ["PATH": "/usr/bin:/bin"], request: Data("fixture\n".utf8), timeout: timeout)
    }

    func awaitStarted() async throws {
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: folder.appendingPathComponent("root").path) {
            guard Date() < deadline else { throw NotebookLMGatewayClientError.launchFailed }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func assertStopped(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
        let pid = try XCTUnwrap(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), file: file, line: line)
        XCTAssertTrue(OwnedProcessTermination.isZombie(pid) || (kill(pid, 0) == -1 && errno == ESRCH),
                      "Owned fixture still running or inaccessible", file: file, line: line)
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }
    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
