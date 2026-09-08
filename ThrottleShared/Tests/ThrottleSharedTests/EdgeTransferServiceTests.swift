import Foundation
@testable import ThrottleShared
import XCTest

final class EdgeTransferServiceTests: XCTestCase {
    private let transferID = "12345678-1234-1234-1234-123456789abc"
    private let serverID = "22345678-1234-1234-1234-123456789abc"

    private var input: EdgeTransferService.Input {
        .init(id: transferID, runtime: "codex", nativeSessionID: transferID,
              sourceCwd: "/source", remoteCwd: "/remote/" + transferID,
              filename: "rollout-2026-09-07T12-00-00-\(transferID).jsonl",
              baselineSHA256: String(repeating: "a", count: 64), project: "Fixture")
    }

    private func record(_ mutate: (inout [String: Any]) -> Void = { _ in }) throws -> EdgeTransferService.Record {
        let encodedInput = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input))
        let unit = "throttle-transfer-\(transferID).service"
        var object: [String: Any] = [
            "contractVersion": 2, "id": transferID, "serverID": serverID, "input": encodedInput, "phase": "stopped",
            "stopReceipt": ["bootID": serverID, "invocationID": String(repeating: "b", count: 32),
                            "unit": unit, "controlGroup": "/system.slice/\(unit)",
                            "activeState": "inactive", "populated": 0, "observedAt": 1_788_800_000_000.0]
        ]
        mutate(&object)
        return try JSONDecoder().decode(EdgeTransferService.Record.self,
                                        from: JSONSerialization.data(withJSONObject: object))
    }

    func testExactStopReceiptAcceptsOnlyItsServerAndTransferBinding() throws {
        let result = try record()
        XCTAssertNoThrow(try result.validate(serverID: serverID, input: input))
        XCTAssertThrowsError(try result.validate(serverID: UUID().uuidString, input: input))
        for field in ["serverID", "id", "input"] {
            let changed = try record { $0[field] = field == "input" ? NSNull() : UUID().uuidString }
            XCTAssertThrowsError(try changed.validate(serverID: serverID, input: input))
        }
    }

    func testPopulatedWrongUnitOrUnconfirmedStateCannotAuthorizeReturn() throws {
        let invalid: [(String, Any)] = [("populated", 1), ("activeState", "active"), ("unit", "another.service"),
            ("controlGroup", "/foreign"), ("bootID", ""), ("invocationID", ""), ("observedAt", 0)
        ]
        for (key, value) in invalid {
            let result = try record {
                var receipt = $0["stopReceipt"] as? [String: Any] ?? [:]
                receipt[key] = value
                $0["stopReceipt"] = receipt
            }
            XCTAssertThrowsError(try result.validate(serverID: serverID, input: input), key)
        }
        let missing = try record { $0.removeValue(forKey: "stopReceipt") }
        XCTAssertThrowsError(try missing.validate(serverID: serverID, input: input))
        let contradictory = try record { $0["phase"] = "remote" }
        XCTAssertThrowsError(try contradictory.validate(serverID: serverID, input: input))
    }

    func testEmbeddedAgentPreservesTheModuleAndRejectsAmbiguousPackaging() throws {
        let module = "export const contract = 2;"
        let fresh = "import { contract } from './transfer-runtime.mjs'; export const fresh = contract;"
        let source = """
        import { contract } from './transfer-runtime.mjs';
        import { fresh } from './fresh-runtime.mjs';
        """
        let bundled = try XCTUnwrap(EdgeAgentService.embeddedAgentSource(
            source, transferModule: module, freshModule: fresh))
        let encoded = bundled.components(separatedBy: "base64,").dropFirst().compactMap {
            $0.split(separator: "'").first.map(String.init)
        }
        XCTAssertEqual(encoded.count, 2)
        XCTAssertEqual(Data(base64Encoded: encoded[0]), Data(module.utf8))
        let nested = try XCTUnwrap(Data(base64Encoded: encoded[1]))
        let nestedSource = try XCTUnwrap(String(data: nested, encoding: .utf8))
        XCTAssertTrue(nestedSource.contains("'data:text/javascript;base64,\(encoded[0])'"))
        XCTAssertFalse(nestedSource.contains("'./transfer-runtime.mjs'"))
        XCTAssertFalse(bundled.contains("'./fresh-runtime.mjs'"))
        XCTAssertNil(EdgeAgentService.embeddedAgentSource(source + source, transferModule: module, freshModule: fresh))
        XCTAssertNil(EdgeAgentService.embeddedAgentSource(source, transferModule: module, freshModule: fresh + fresh))
        XCTAssertNil(EdgeAgentService.embeddedAgentSource("missing module", transferModule: module, freshModule: fresh))
    }
    func testMissingMetadataOnlyAcceptsConfirmedStopForReconciliation() throws {
        let stopped = try record { $0["input"] = NSNull() }
        XCTAssertNoThrow(try stopped.validate(serverID: serverID, input: input, allowMissingStoppedInput: true))
        XCTAssertThrowsError(try stopped.validate(serverID: serverID, input: input))
        for phase in ["prepared", "starting", "remote", "frozen"] {
            let invalid = try record { $0["input"] = NSNull(); $0["phase"] = phase }
            XCTAssertThrowsError(try invalid.validate(serverID: serverID, input: input, allowMissingStoppedInput: true))
        }
        let noProof = try record { $0["input"] = NSNull(); $0.removeValue(forKey: "stopReceipt") }
        XCTAssertThrowsError(try noProof.validate(serverID: serverID, input: input, allowMissingStoppedInput: true))
    }

}
