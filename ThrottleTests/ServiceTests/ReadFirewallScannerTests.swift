@testable import Throttle
import XCTest

final class ReadFirewallScannerTests: XCTestCase {
    func test_flagsThreeSequentialReadsAcrossInterleavedResults() {
        let lines = [
            user("inspect"),
            assistantRead(id: "r1", path: "/repo/A.swift"),
            result(id: "r1", text: "one"),
            assistantRead(id: "r2", path: "/repo/B.swift"),
            result(id: "r2", text: "two"),
            assistantRead(id: "r3", path: "/repo/C.swift"),
            result(id: "r3", text: "three")
        ]
        let summary = ReadFirewallScanner.scan(lines: lines)
        XCTAssertTrue(summary.highWaste)
        XCTAssertEqual(summary.heavyTurns, 1)
        XCTAssertEqual(summary.totalReads, 3)
    }

    func test_nonReadToolBreaksSequentialReads() {
        let lines = [
            user("inspect"),
            assistantRead(id: "r1", path: "/repo/A"),
            assistantTool(id: "g1", name: "Grep"),
            assistantRead(id: "r2", path: "/repo/B"),
            assistantRead(id: "r3", path: "/repo/C")
        ]
        XCTAssertEqual(ReadFirewallScanner.scan(lines: lines).heavyTurns, 0)
    }

    func test_flagsMoreThan150KBReadPayloadInOneTurn() {
        let payload = String(repeating: "x", count: ReadFirewallScanner.byteThreshold + 1)
        let summary = ReadFirewallScanner.scan(lines: [
            user("read it"), assistantRead(id: "r1", path: "/repo/huge"),
            result(id: "r1", text: payload)
        ])
        XCTAssertEqual(summary.oversizedTurns, 1)
        XCTAssertEqual(summary.loadedBytes, payload.utf8.count)
    }

    func test_installerDefinitionPinsRequestedLocalStack() throws {
        let definition = ReadFirewallInstaller.definition
        let env = try XCTUnwrap(definition["env"] as? [String: String])
        let args = try XCTUnwrap(definition["args"] as? [String])
        XCTAssertEqual(env["EMBEDDING_MODEL"], "Xenova/all-MiniLM-L6-v2")
        XCTAssertEqual(env["VECTOR_STORE"], "lancedb")
        XCTAssertTrue(args.contains("mcp-local-rag"))
    }

    private func user(_ text: String) -> String {
        #"{"type":"user","message":{"role":"user","content":"\#(text)"}}"#
    }
    private func assistantRead(id: String, path: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"read_file","input":{"path":"\#(path)"}}]}}"#
    }
    private func assistantTool(id: String, name: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}]}}"#
    }
    private func result(id: String, text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [
            "type": "user",
            "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": id, "content": text]
            ]]
        ])
        return String(decoding: data, as: UTF8.self)
    }
}
