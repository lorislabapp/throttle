import Foundation
import XCTest
import ResearchVaultModel

final class ResearchReceiptTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_787_832_000)
    private let sourceHash = String(repeating: "a", count: 64)

    func testSealingIsDeterministicAndValid() throws {
        let first = try makeReceipt()
        let second = try makeReceipt()

        XCTAssertEqual(first.contentHash, second.contentHash)
        XCTAssertNoThrow(try ResearchReceiptValidator.validate(first))
    }

    func testTamperedReceiptFailsClosed() throws {
        let sealed = try makeReceipt()
        let tampered = ResearchReceipt(
            schemaVersion: sealed.schemaVersion,
            receiptID: sealed.receiptID,
            sessionID: sealed.sessionID,
            agentID: sealed.agentID,
            projectKey: sealed.projectKey,
            question: "A different question",
            findings: sealed.findings,
            sources: sealed.sources,
            sensitivity: sealed.sensitivity,
            createdAt: sealed.createdAt,
            contentHash: sealed.contentHash
        )

        XCTAssertThrowsError(try ResearchReceiptValidator.validate(tampered)) { error in
            XCTAssertEqual(error as? ResearchReceiptValidationError, .contentHashMismatch)
        }
    }

    func testSupportedClaimRequiresKnownEvidence() throws {
        XCTAssertThrowsError(
            try ResearchReceipt.seal(
                receiptID: "8f6ff598-fc26-4ad8-a3d7-fc16bcd7e1a0",
                sessionID: "session-1",
                agentID: "agent-1",
                projectKey: "throttle",
                question: "What is supported?",
                findings: [
                    ResearchFinding(
                        claim: "A claim",
                        status: .supported,
                        evidenceIDs: ["missing"]
                    ),
                ],
                sources: [],
                sensitivity: .internal,
                createdAt: instant
            )
        ) { error in
            XCTAssertEqual(
                error as? ResearchReceiptValidationError,
                .missingEvidence(findingIndex: 0, evidenceID: "missing")
            )
        }
    }

    func testVerifiedClaimCannotOmitEvidence() throws {
        XCTAssertThrowsError(
            try ResearchReceipt.seal(
                receiptID: "8f6ff598-fc26-4ad8-a3d7-fc16bcd7e1a0",
                sessionID: "session-1",
                agentID: "agent-1",
                projectKey: "throttle",
                question: "What is verified?",
                findings: [
                    ResearchFinding(claim: "A claim", status: .verified, evidenceIDs: []),
                ],
                sources: [],
                sensitivity: .internal,
                createdAt: instant
            )
        ) { error in
            XCTAssertEqual(
                error as? ResearchReceiptValidationError,
                .evidenceRequired(findingIndex: 0)
            )
        }
    }

    func testDuplicateSourceIDsFailClosed() throws {
        let source = ResearchSource(
            id: "source-1",
            kind: .file,
            locator: "one.md",
            observedAt: instant,
            sha256: sourceHash
        )
        XCTAssertThrowsError(
            try ResearchReceipt.seal(
                receiptID: "8f6ff598-fc26-4ad8-a3d7-fc16bcd7e1a0",
                sessionID: "session-1",
                agentID: "agent-1",
                projectKey: "throttle",
                question: "Are IDs unique?",
                findings: [],
                sources: [source, source],
                sensitivity: .internal,
                createdAt: instant
            )
        ) { error in
            XCTAssertEqual(
                error as? ResearchReceiptValidationError,
                .duplicateSourceID("source-1")
            )
        }
    }

    func testProjectKeyRejectsPathsAndTraversal() throws {
        for projectKey in ["../cheatcode", "/tmp/vault", "Throttle"] {
            XCTAssertThrowsError(
                try ResearchReceipt.seal(
                    receiptID: "8f6ff598-fc26-4ad8-a3d7-fc16bcd7e1a0",
                    sessionID: "session-1",
                    agentID: "agent-1",
                    projectKey: projectKey,
                    question: "Is the project key safe?",
                    findings: [],
                    sources: [],
                    sensitivity: .internal,
                    createdAt: instant
                )
            ) { error in
                XCTAssertEqual(error as? ResearchReceiptValidationError, .invalidProjectKey)
            }
        }
    }

    func testAuthorizationHasNoImplicitWildcard() {
        let authorization = VaultAuthorization(
            projectKeys: ["throttle"],
            maximumSensitivity: .confidential
        )

        XCTAssertTrue(authorization.permits(projectKey: "throttle", sensitivity: .internal))
        XCTAssertFalse(authorization.permits(projectKey: "cheatcode", sensitivity: .public))
        XCTAssertFalse(authorization.permits(projectKey: "throttle", sensitivity: .restricted))
        XCTAssertFalse(
            VaultAuthorization(projectKeys: [], maximumSensitivity: .restricted)
                .permits(projectKey: "throttle", sensitivity: .public)
        )
    }

    private func makeReceipt() throws -> ResearchReceipt {
        try ResearchReceipt.seal(
            receiptID: "8f6ff598-fc26-4ad8-a3d7-fc16bcd7e1a0",
            sessionID: "session-1",
            agentID: "agent-1",
            projectKey: "throttle",
            question: "How should research be stored?",
            findings: [
                ResearchFinding(
                    claim: "Receipts are the stable boundary.",
                    status: .supported,
                    evidenceIDs: ["source-1"]
                ),
            ],
            sources: [
                ResearchSource(
                    id: "source-1",
                    kind: .file,
                    locator: "docs/research/example.md",
                    observedAt: instant,
                    sha256: sourceHash
                ),
            ],
            sensitivity: .internal,
            createdAt: instant
        )
    }
}
