import CryptoKit
import Foundation
import ThrottleVaultContract
import XCTest

/// Holds the sealed-receipt contract to `Conformance/receipt-vectors.json`.
///
/// A receipt's content hash is SHA-256 over a canonical JSON encoding. Another
/// implementation can only validate a Throttle receipt if it reproduces those
/// bytes exactly, so the vectors store the canonical payload itself, not just
/// the hash. Run with `THROTTLE_REGENERATE_VECTORS=1` to rewrite the file from
/// this implementation; without it, the file is the authority and any drift
/// fails.
final class ReceiptVectorTests: XCTestCase {

    // MARK: - The canonical form, restated from the outside

    /// Mirrors the private payload field for field. If this ever diverges from
    /// the sealed type, `testCanonicalBytesReproduceTheSealedHash` fails, which
    /// is the point: the canonicalization must be expressible without access to
    /// the implementation.
    private struct CanonicalPayload: Encodable {
        let schemaVersion: Int
        let receiptID: String
        let sessionID: String
        let agentID: String
        let parentAgentID: String?
        let projectKey: String
        let question: String
        let findings: [ResearchFinding]
        let sources: [ResearchSource]
        let openQuestions: [String]
        let sensitivity: ResearchSensitivity
        let createdAt: Date

        init(_ receipt: ResearchReceipt) {
            schemaVersion = receipt.schemaVersion
            receiptID = receipt.receiptID
            sessionID = receipt.sessionID
            agentID = receipt.agentID
            parentAgentID = receipt.parentAgentID
            projectKey = receipt.projectKey
            question = receipt.question
            findings = receipt.findings
            sources = receipt.sources
            openQuestions = receipt.openQuestions
            sensitivity = receipt.sensitivity
            createdAt = receipt.createdAt
        }
    }

    private static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func wireDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Fixed, synthetic inputs

    private struct SealCase {
        let name: String
        let note: String
        let receipt: ResearchReceipt
    }

    private struct RejectCase {
        let name: String
        let error: String
        let receipt: [String: Any]
    }

    private static let hashA = String(repeating: "a", count: 64)
    private static let hashB = String(repeating: "b", count: 64)
    private static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private static func sealed() throws -> [SealCase] {
        let minimal = try ResearchReceipt.seal(
            receiptID: "00000000-0000-4000-8000-000000000001",
            sessionID: "session-1", agentID: "agent-1", projectKey: "example",
            question: "What does the fixture claim?",
            findings: [ResearchFinding(claim: "The fixture exists.", status: .verified, evidenceIDs: ["s1"])],
            sources: [ResearchSource(id: "s1", kind: .file, locator: "notes/fixture.md",
                                     observedAt: epoch, sha256: hashA)],
            sensitivity: .internal, createdAt: epoch
        )
        let rich = try ResearchReceipt.seal(
            receiptID: "00000000-0000-4000-8000-000000000002",
            sessionID: "session-2", agentID: "agent-2", parentAgentID: "agent-parent",
            projectKey: "example.project_2",
            question: "Café, 日本語 and a/slash — are they preserved?",
            findings: [
                ResearchFinding(claim: "Unicode is kept as written: é, 日本語.", status: .supported,
                                evidenceIDs: ["s1", "s2"]),
                ResearchFinding(claim: "Still open.", status: .open, evidenceIDs: [])
            ],
            sources: [
                ResearchSource(id: "s1", kind: .url, locator: "https://example.com/a/b?c=d",
                               observedAt: epoch, sha256: hashA),
                ResearchSource(id: "s2", kind: .repository, locator: "example/repo",
                               observedAt: epoch.addingTimeInterval(60), sha256: hashB)
            ],
            openQuestions: ["Is the slash escaped?", "Is the order of keys stable?"],
            sensitivity: .confidential, createdAt: epoch.addingTimeInterval(1)
        )
        return [
            SealCase(name: "minimal",
                     note: "One verified finding, one source, no parent, no open question, whole-second dates.",
                     receipt: minimal),
            SealCase(name: "unicode-slashes-parent-open",
                     note: "Non-ASCII text, slashes left unescaped, a parent agent, "
                        + "an OPEN finding without evidence and open questions.",
                     receipt: rich)
        ]
    }

    // MARK: - Rejections

    private static func rejections(from base: ResearchReceipt) throws -> [RejectCase] {
        let data = try canonicalEncoder().encode(base)
        func variant(_ mutate: (inout [String: Any]) -> Void) throws -> [String: Any] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            mutate(&object)
            return object
        }
        return [
            RejectCase(name: "unsupported-schema", error: "unsupported_schema_version",
             receipt: try variant { $0["schemaVersion"] = 2 }),
            RejectCase(name: "receipt-id-not-a-uuid", error: "invalid_receipt_id",
             receipt: try variant { $0["receiptID"] = "not-a-uuid" }),
            RejectCase(name: "project-key-uppercase", error: "invalid_project_key",
             receipt: try variant { $0["projectKey"] = "Example" }),
            RejectCase(name: "blank-question", error: "empty_field",
             receipt: try variant { $0["question"] = "   " }),
            RejectCase(name: "source-hash-not-sha256", error: "invalid_sha256",
             receipt: try variant {
                 var sources = $0["sources"] as? [[String: Any]] ?? []
                 sources[0]["sha256"] = "ABC"
                 $0["sources"] = sources
             }),
            RejectCase(name: "verified-without-evidence", error: "evidence_required",
             receipt: try variant {
                 var findings = $0["findings"] as? [[String: Any]] ?? []
                 findings[0]["evidenceIDs"] = []
                 $0["findings"] = findings
             }),
            RejectCase(name: "evidence-to-unknown-source", error: "missing_evidence",
             receipt: try variant {
                 var findings = $0["findings"] as? [[String: Any]] ?? []
                 findings[0]["evidenceIDs"] = ["s9"]
                 $0["findings"] = findings
             }),
            RejectCase(name: "tampered-claim", error: "content_hash_mismatch",
             receipt: try variant {
                 var findings = $0["findings"] as? [[String: Any]] ?? []
                 findings[0]["claim"] = "The fixture exists, and more."
                 $0["findings"] = findings
             })
        ]
    }

    // Explicit on purpose: a name derived from the case label would turn
    // `invalidSHA256` into `invalid_s_h_a256`. One case per portable name, as
    // the production validator does for its own rules.
    // swiftlint:disable:next cyclomatic_complexity
    private static func errorName(_ error: Error) -> String {
        switch error as? ResearchReceiptValidationError {
        case .unsupportedSchemaVersion: return "unsupported_schema_version"
        case .invalidReceiptID: return "invalid_receipt_id"
        case .invalidProjectKey: return "invalid_project_key"
        case .emptyField: return "empty_field"
        case .valueTooLong: return "value_too_long"
        case .duplicateSourceID: return "duplicate_source_id"
        case .invalidSHA256: return "invalid_sha256"
        case .missingEvidence: return "missing_evidence"
        case .evidenceRequired: return "evidence_required"
        case .contentHashMismatch: return "content_hash_mismatch"
        case nil: return "not_a_validation_error"
        }
    }

    // MARK: - File

    private static var vectorsURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Conformance/receipt-vectors.json")
    }

    private static func document() throws -> [String: Any] {
        let encoder = canonicalEncoder()
        let sealed = try sealed()
        let seals: [[String: Any]] = try sealed.map { item in
            let (name, note, receipt) = (item.name, item.note, item.receipt)
            let canonical = try encoder.encode(CanonicalPayload(receipt))
            return [
                "name": name, "note": note,
                "receipt": try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(receipt))),
                "canonical_payload_utf8": try XCTUnwrap(String(data: canonical, encoding: .utf8)),
                "content_hash": receipt.contentHash
            ]
        }
        let rejects: [[String: Any]] = try rejections(from: sealed[0].receipt).map { item in
            ["name": item.name, "expect_error": item.error, "receipt": item.receipt]
        }
        return [
            "contract": "Throttle Research Vault sealed receipt",
            "schema_version": ResearchReceipt.currentSchemaVersion,
            "canonicalization": [
                "hash": "lowercase hex SHA-256 of the canonical payload UTF-8 bytes",
                "payload": "every receipt field except contentHash",
                "json": "keys sorted, no insignificant whitespace, forward slashes not escaped, "
                    + "non-ASCII characters written literally",
                "absent_optional": "a nil optional field is omitted, not written as null",
                "dates": "milliseconds since 1970-01-01T00:00:00Z as a JSON number",
                "known_risk": "fractional milliseconds are written with the platform's floating-point "
                    + "formatting; vectors use whole seconds so they stay portable"
            ],
            "seal_vectors": seals,
            "reject_vectors": rejects
        ]
    }

    // MARK: - Tests

    func testCanonicalBytesReproduceTheSealedHash() throws {
        for item in try Self.sealed() {
            let (name, receipt) = (item.name, item.receipt)
            let canonical = try Self.canonicalEncoder().encode(CanonicalPayload(receipt))
            XCTAssertEqual(Self.sha256(canonical), receipt.contentHash,
                           "\(name): the canonical form restated here no longer matches the sealed hash")
        }
    }

    func testTheVectorFileIsTheAuthority() throws {
        let fresh = try Self.document()
        if ProcessInfo.processInfo.environment["THROTTLE_REGENERATE_VECTORS"] == "1" {
            let data = try JSONSerialization.data(withJSONObject: fresh,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try (data + Data("\n".utf8)).write(to: Self.vectorsURL)
            return
        }
        let stored = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: Self.vectorsURL)) as? [String: Any]
        )
        let seals = try XCTUnwrap(stored["seal_vectors"] as? [[String: Any]])
        XCTAssertFalse(seals.isEmpty)
        for vector in seals {
            let name = vector["name"] as? String ?? "?"
            let canonical = try XCTUnwrap(vector["canonical_payload_utf8"] as? String)
            let hash = try XCTUnwrap(vector["content_hash"] as? String)
            XCTAssertEqual(Self.sha256(Data(canonical.utf8)), hash, "\(name): stored bytes do not hash to stored hash")
            let receiptData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(vector["receipt"]))
            let receipt = try Self.wireDecoder().decode(ResearchReceipt.self, from: receiptData)
            XCTAssertEqual(receipt.contentHash, hash, name)
            XCTAssertNoThrow(try ResearchReceiptValidator.validate(receipt), "\(name): a stored seal must validate")
            let restated = try Self.canonicalEncoder().encode(CanonicalPayload(receipt))
            XCTAssertEqual(String(data: restated, encoding: .utf8), canonical,
                           "\(name): this implementation no longer produces the stored canonical bytes")
        }
        let rejects = try XCTUnwrap(stored["reject_vectors"] as? [[String: Any]])
        XCTAssertFalse(rejects.isEmpty)
        for vector in rejects {
            let name = vector["name"] as? String ?? "?"
            let expected = try XCTUnwrap(vector["expect_error"] as? String)
            let receiptData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(vector["receipt"]))
            let receipt = try Self.wireDecoder().decode(ResearchReceipt.self, from: receiptData)
            XCTAssertThrowsError(try ResearchReceiptValidator.validate(receipt), name) { error in
                XCTAssertEqual(Self.errorName(error), expected, name)
            }
        }
    }
}
