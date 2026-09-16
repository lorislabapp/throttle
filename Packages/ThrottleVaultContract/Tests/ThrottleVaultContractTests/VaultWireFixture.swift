import Foundation
import ThrottleVaultContract

/// Synthetic wire samples for every request/response type of the vault client
/// contract, serialized with the product wire codec (sorted keys, unescaped
/// slashes, millisecond dates). The same source produced the pre-extraction
/// fixture from the original product modules; the standalone package must
/// reproduce every object byte-for-byte after canonical JSON comparison.
enum VaultWireFixture {
    static let observedAt = Date(timeIntervalSince1970: 1_787_832_000)
    static let modifiedAt = Date(timeIntervalSince1970: 1_787_745_600)
    static let receiptID = "8f6ff598-fc26-4ad8-a3d7-fc16bcd7e1a0"
    static let otherReceiptID = "0d3c2b3e-6a4f-4c9d-9a3e-2f1b7c8d9e0f"
    static let factID = String(repeating: "0123456789abcdef", count: 4)
    static let otherFactID = String(repeating: "fedcba9876543210", count: 4)
    static let sha256 = String(repeating: "ab", count: 32)

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    static func source() -> ResearchSource {
        ResearchSource(
            id: "src-1",
            kind: .file,
            locator: "/synthetic/path.md",
            observedAt: observedAt,
            sha256: sha256
        )
    }

    static func sealedReceipt() throws -> ResearchReceipt {
        try ResearchReceipt.seal(
            receiptID: receiptID,
            sessionID: "synthetic-session",
            agentID: "synthetic-agent",
            parentAgentID: "synthetic-parent",
            projectKey: "throttle",
            question: "Synthetic question?",
            findings: [ResearchFinding(claim: "Synthetic claim", status: .supported, evidenceIDs: ["src-1"])],
            sources: [source()],
            openQuestions: ["Synthetic open question"],
            sensitivity: .internal,
            createdAt: observedAt
        )
    }

    static func citation() -> ResearchVaultCitation {
        ResearchVaultCitation(
            documentID: "doc-1",
            title: "Synthetic title",
            libraryPath: "library/synthetic.md",
            origins: ["manual"],
            plaintextSHA256: sha256,
            chunkOrdinal: 2,
            locator: "synthetic.md#L10",
            excerptSHA256: sha256,
            observedAt: observedAt,
            sourceModifiedAt: modifiedAt,
            evidenceStatus: .supported,
            indexGeneration: "gen-1",
            receiptProvenance: ResearchVaultReceiptProvenance(
                receiptID: receiptID,
                sealedContentHash: sha256,
                findingIndex: 0,
                sources: [source()]
            )
        )
    }

    static func identity() throws -> ResearchVaultCodeIdentity {
        try ResearchVaultCodeIdentity(
            signingIdentifier: "com.example.synthetic-client",
            teamIdentifier: "ABCDE12345"
        )
    }

    // swiftlint:disable:next function_body_length
    static func samples() throws -> [String: Any] {
        let receipt = try sealedReceipt()
        var samples: [String: Any] = [:]
        func put<Value: Encodable>(_ name: String, _ value: Value) throws {
            samples[name] = try JSONSerialization.jsonObject(with: encoder().encode(value))
        }
        try put("searchRequest", ResearchVaultSearchRequest(
            query: "synthetic vault query",
            limit: 4,
            maximumCharacters: 2_048,
            projectKeys: ["throttle", "cheatcode"]
        ))
        try put("contextBundle", ResearchVaultContextBundle(
            query: "synthetic vault query",
            projectKeys: ["throttle"],
            maximumSensitivity: .internal,
            items: [ResearchVaultContextItem(
                citation: citation(),
                heading: "Synthetic heading",
                excerpt: "Synthetic excerpt with / slash",
                score: 0.75
            )],
            truncated: false
        ))
        try put("healthResponse", ResearchVaultHealthResponse(
            schemaVersion: 4,
            cipherVersion: "4.18.0",
            receiptCount: 3,
            documentCount: 2,
            chunkCount: 9,
            quickCheckPassed: true,
            cipherIntegrityPassed: true,
            foreignKeysPassed: true
        ))
        try put("errorPayload", ResearchVaultIPCErrorPayload(code: .invalidRequest))
        try put(
            "projectAdmissionRequest",
            ResearchVaultProjectAdmissionRequest(projectKeys: ["throttle", "cheatcode"])
        )
        try put(
            "projectAdmissionResponse",
            ResearchVaultProjectAdmissionResponse(projectKeys: ["throttle", "cheatcode"])
        )
        try put("receiptImportRequest", ResearchVaultReceiptImportRequest(receipts: [receipt]))
        try put(
            "receiptImportResponse",
            ResearchVaultReceiptImportResponse(insertedReceipts: 1, alreadyPresentReceipts: 0)
        )
        try put("quarantineListRequest", ResearchVaultQuarantineListRequest())
        try put("quarantineListResponse", ResearchVaultQuarantineListResponse(items: [ResearchVaultQuarantineItem(
            receiptID: receiptID,
            projectKey: "throttle",
            question: "Synthetic question?",
            sensitivity: "internal",
            createdAtMS: 1_787_832_000_000,
            sourceCount: 1,
            firstSourceLocator: "/synthetic/path.md"
        )]))
        try put("reviewRequest", ResearchVaultReviewRequest(action: .approve, receiptIDs: [receiptID]))
        try put("reviewResponse", ResearchVaultReviewResponse(processed: 1))
        try put("receiptExportRequest", ResearchVaultReceiptExportRequest(afterReceiptID: receiptID, limit: 8))
        try put(
            "receiptExportResponse",
            ResearchVaultReceiptExportResponse(receipts: [receipt], nextReceiptID: receiptID)
        )
        try put("reasoningPromotionRequest", ResearchVaultReasoningPromotionRequest(
            relations: [ResearchVaultReasoningRelation(
                relation: .supersedes,
                subject: ResearchVaultReasoningClaimReference(receiptID: receiptID, findingIndex: 0),
                object: ResearchVaultReasoningClaimReference(receiptID: otherReceiptID, findingIndex: 1),
                validFrom: modifiedAt,
                validUntil: observedAt
            )],
            removingFactIDs: [otherFactID]
        ))
        try put("reasoningRefreshResponse", ResearchVaultReasoningRefreshResponse(
            generation: 7,
            baseFactCount: 12,
            derivedFactCount: 3,
            relationCount: 1,
            shadowMode: true
        ))
        try put("reasoningQuery", ResearchVaultReasoningQuery(kind: .why, factID: factID, limit: 16))
        try put("reasoningQueryResponse", ResearchVaultReasoningQueryResponse(
            kind: .why,
            generation: 7,
            facts: [ResearchVaultReasoningFactDTO(
                id: factID,
                predicate: "supersedes",
                arguments: [receiptID, otherReceiptID],
                projectKey: "throttle",
                sensitivity: .internal,
                asserted: true,
                receiptIDs: [receiptID],
                sourceIDs: ["src-1"]
            )],
            derivations: [ResearchVaultReasoningDerivationDTO(
                conclusionFactID: factID,
                ruleID: "rule-1",
                premiseFactIDs: [otherFactID]
            )],
            addedFactIDs: [factID],
            removedFactIDs: [],
            updatedFactIDs: [otherFactID],
            truncated: false
        ))
        return samples
    }

    static func constants() -> [String: Int] {
        [
            "contractVersion": ResearchVaultIPCContract.currentVersion,
            "maximumQueryBytes": ResearchVaultIPCContract.maximumQueryBytes,
            "maximumSearchRequestBytes": ResearchVaultIPCContract.maximumSearchRequestBytes,
            "maximumResultCharacters": ResearchVaultIPCContract.maximumResultCharacters,
            "maximumOwnerRequestBytes": ResearchVaultIPCContract.maximumOwnerRequestBytes,
            "maximumReceiptsPerRequest": ResearchVaultIPCContract.maximumReceiptsPerRequest,
            "maximumResponseBytes": ResearchVaultIPCContract.maximumResponseBytes,
            "maximumReasoningRelations": ResearchVaultIPCContract.maximumReasoningRelations,
            "maximumReasoningFactsPerResponse": ResearchVaultIPCContract.maximumReasoningFactsPerResponse,
            "citationSchemaVersion": ResearchVaultCitation.currentSchemaVersion,
            "receiptSchemaVersion": ResearchReceipt.currentSchemaVersion
        ]
    }

    static func serviceContract() -> [String: String] {
        [
            "cheatCodeQueryServiceName": ResearchVaultServiceContract.cheatCodeQueryServiceName,
            "throttleQueryServiceName": ResearchVaultServiceContract.throttleQueryServiceName,
            "throttleOwnerServiceName": ResearchVaultServiceContract.throttleOwnerServiceName,
            "serviceSigningIdentifier": ResearchVaultServiceContract.serviceSigningIdentifier,
            "teamIdentifier": ResearchVaultServiceContract.teamIdentifier
        ]
    }

    static func capture() throws -> [String: Any] {
        [
            "samples": try samples(),
            "constants": constants(),
            "serviceContract": serviceContract(),
            "distributionRequirement": try identity().distributionRequirement
        ]
    }
}
