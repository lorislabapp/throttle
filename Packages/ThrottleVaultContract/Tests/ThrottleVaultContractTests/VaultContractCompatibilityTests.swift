import Foundation
import ThrottleVaultContract
import XCTest

final class VaultContractCompatibilityTests: XCTestCase {
    func testWireSamplesMatchThePreExtractionCapture() throws {
        let expected = try samples()
        let actual = try VaultWireFixture.samples()
        XCTAssertEqual(Set(actual.keys), Set(expected.keys))
        for (name, object) in expected {
            XCTAssertEqual(
                try XCTUnwrap(actual[name] as? NSDictionary),
                try XCTUnwrap(object as? NSDictionary),
                name
            )
        }
    }

    func testContractConstantsServiceNamesAndRequirementAreUnchanged() throws {
        let fixture = try fixture()
        XCTAssertEqual(try XCTUnwrap(fixture["constants"] as? [String: Int]), VaultWireFixture.constants())
        XCTAssertEqual(
            try XCTUnwrap(fixture["serviceContract"] as? [String: String]),
            VaultWireFixture.serviceContract()
        )
        XCTAssertEqual(
            try XCTUnwrap(fixture["distributionRequirement"] as? String),
            try VaultWireFixture.identity().distributionRequirement
        )
    }

    func testEverySampleRoundTripsThroughTheWireCodec() throws {
        let samples = try samples()
        func check<Value: Codable & Equatable>(_ name: String, _: Value.Type) throws {
            let object = try XCTUnwrap(samples[name] as? NSDictionary, name)
            let data = try JSONSerialization.data(withJSONObject: object)
            let value = try VaultWireFixture.decoder().decode(Value.self, from: data)
            let encoded = try VaultWireFixture.encoder().encode(value)
            XCTAssertEqual(try VaultWireFixture.decoder().decode(Value.self, from: encoded), value, name)
            XCTAssertEqual(try self.object(encoded), object, name)
        }
        try check("searchRequest", ResearchVaultSearchRequest.self)
        try check("contextBundle", ResearchVaultContextBundle.self)
        try check("healthResponse", ResearchVaultHealthResponse.self)
        try check("errorPayload", ResearchVaultIPCErrorPayload.self)
        try check("projectAdmissionRequest", ResearchVaultProjectAdmissionRequest.self)
        try check("projectAdmissionResponse", ResearchVaultProjectAdmissionResponse.self)
        try check("receiptImportRequest", ResearchVaultReceiptImportRequest.self)
        try check("receiptImportResponse", ResearchVaultReceiptImportResponse.self)
        try check("quarantineListRequest", ResearchVaultQuarantineListRequest.self)
        try check("quarantineListResponse", ResearchVaultQuarantineListResponse.self)
        try check("reviewRequest", ResearchVaultReviewRequest.self)
        try check("reviewResponse", ResearchVaultReviewResponse.self)
        try check("receiptExportRequest", ResearchVaultReceiptExportRequest.self)
        try check("receiptExportResponse", ResearchVaultReceiptExportResponse.self)
        try check("reasoningPromotionRequest", ResearchVaultReasoningPromotionRequest.self)
        try check("reasoningRefreshResponse", ResearchVaultReasoningRefreshResponse.self)
        try check("reasoningQuery", ResearchVaultReasoningQuery.self)
        try check("reasoningQueryResponse", ResearchVaultReasoningQueryResponse.self)
    }

    func testSealedReceiptHashIsStableAndTamperingIsRejected() throws {
        let request = try XCTUnwrap(try samples()["receiptImportRequest"] as? [String: Any])
        let receipts = try XCTUnwrap(request["receipts"] as? [[String: Any]])
        let captured = try XCTUnwrap(receipts.first)
        let golden = try XCTUnwrap(captured["contentHash"] as? String)

        let resealed = try VaultWireFixture.sealedReceipt()
        XCTAssertEqual(resealed.contentHash, golden)
        XCTAssertNoThrow(try ResearchReceiptValidator.validate(resealed))

        let decoded = try VaultWireFixture.decoder().decode(
            ResearchReceipt.self, from: JSONSerialization.data(withJSONObject: captured)
        )
        XCTAssertEqual(decoded, resealed)
        XCTAssertNoThrow(try ResearchReceiptValidator.validate(decoded))

        var tampered = captured
        tampered["question"] = "Tampered question?"
        let forged = try VaultWireFixture.decoder().decode(
            ResearchReceipt.self, from: JSONSerialization.data(withJSONObject: tampered)
        )
        XCTAssertThrowsError(try ResearchReceiptValidator.validate(forged)) { error in
            XCTAssertEqual(error as? ResearchReceiptValidationError, .contentHashMismatch)
        }
        expectValidation(.invalidReceipt) {
            try ResearchVaultReceiptImportRequest(receipts: [forged]).validated()
        }
    }

    func testOwnerRequestValidationRefusesOutOfContractInput() throws {
        let receipt = try VaultWireFixture.sealedReceipt()
        let receiptID = VaultWireFixture.receiptID
        expectValidation(.unsupportedContractVersion(2)) {
            try ResearchVaultSearchRequest(contractVersion: 2, query: "ok").validated()
        }
        expectValidation(.unsupportedContractVersion(0)) {
            try ResearchVaultQuarantineListRequest(contractVersion: 0).validated()
        }
        expectValidation(.invalidReceiptBatch) {
            try ResearchVaultReceiptImportRequest(receipts: []).validated()
        }
        expectValidation(.invalidReceiptBatch) {
            try ResearchVaultReceiptImportRequest(
                receipts: Array(repeating: receipt, count: ResearchVaultIPCContract.maximumReceiptsPerRequest + 1)
            ).validated()
        }
        expectValidation(.invalidReviewBatch) {
            try ResearchVaultReviewRequest(action: .reject, receiptIDs: [receiptID, receiptID]).validated()
        }
        expectValidation(.invalidReviewBatch) {
            try ResearchVaultReviewRequest(action: .approve, receiptIDs: []).validated()
        }
        expectValidation(.invalidExportPage) {
            try ResearchVaultReceiptExportRequest(afterReceiptID: "not-a-uuid").validated()
        }
        expectValidation(.invalidExportPage) {
            try ResearchVaultReceiptExportRequest(limit: ResearchVaultIPCContract.maximumReceiptsPerRequest + 1)
                .validated()
        }
        XCTAssertThrowsError(
            try ResearchVaultProjectAdmissionRequest(projectKeys: (0 ..< 65).map { "project-\($0)" }).validated()
        ) { error in
            XCTAssertEqual(error as? ResearchVaultProjectAdmissionError, .invalidProjects)
        }
        XCTAssertThrowsError(
            try ResearchVaultProjectAdmissionRequest(projectKeys: ["../escape"]).validated()
        ) { error in
            XCTAssertEqual(error as? ResearchVaultProjectAdmissionError, .invalidProjects)
        }
    }

    func testReasoningRequestValidationRefusesOutOfContractInput() {
        let reference = ResearchVaultReasoningClaimReference(receiptID: VaultWireFixture.receiptID, findingIndex: 0)
        expectValidation(.invalidReasoningRelations) {
            try ResearchVaultReasoningPromotionRequest(relations: [
                ResearchVaultReasoningRelation(relation: .contradicts, subject: reference, object: reference)
            ]).validated()
        }
        expectValidation(.invalidReasoningRelations) {
            try ResearchVaultReasoningPromotionRequest(relations: [], removingFactIDs: ["not-hex"]).validated()
        }
        expectValidation(.invalidReasoningQuery) {
            try ResearchVaultReasoningQuery(kind: .why).validated()
        }
        expectValidation(.invalidReasoningQuery) {
            try ResearchVaultReasoningQuery(kind: .facts, factID: VaultWireFixture.factID).validated()
        }
        expectValidation(.invalidReasoningQuery) {
            try ResearchVaultReasoningQuery(
                kind: .facts, limit: ResearchVaultIPCContract.maximumReasoningFactsPerResponse + 1
            ).validated()
        }
    }

    func testContractCarriesNoStorageKeyOrGrantFields() throws {
        let forbidden: Set<String> = [
            "database", "databaseURL", "databasePath", "masterKey", "key", "keychain",
            "authorization", "grant", "token", "secret", "password", "bookmark"
        ]
        var keys = Set<String>()
        func collect(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                keys.formUnion(dictionary.keys)
                dictionary.values.forEach(collect)
            } else if let array = value as? [Any] {
                array.forEach(collect)
            }
        }
        collect(try samples())
        XCTAssertFalse(keys.isEmpty)
        XCTAssertTrue(keys.isDisjoint(with: forbidden), "\(keys.intersection(forbidden))")
    }

    func testCodeIdentityRejectsRequirementInjection() {
        XCTAssertThrowsError(try ResearchVaultCodeIdentity(
            signingIdentifier: "com.example.good\" or true", teamIdentifier: "ABCDE12345"
        )) { error in
            XCTAssertEqual(error as? ResearchVaultXPCConfigurationError, .invalidSigningIdentifier)
        }
        XCTAssertThrowsError(try ResearchVaultCodeIdentity(
            signingIdentifier: "com.example..double", teamIdentifier: "ABCDE12345"
        )) { error in
            XCTAssertEqual(error as? ResearchVaultXPCConfigurationError, .invalidSigningIdentifier)
        }
        XCTAssertThrowsError(try ResearchVaultCodeIdentity(
            signingIdentifier: "com.example.good", teamIdentifier: "TEAM\" OR TRUE"
        )) { error in
            XCTAssertEqual(error as? ResearchVaultXPCConfigurationError, .invalidTeamIdentifier)
        }
    }

    func testResponseEncodingIsBoundedByTheContract() throws {
        func bundle(excerpt: String) -> ResearchVaultContextBundle {
            ResearchVaultContextBundle(
                query: "q", projectKeys: ["throttle"], maximumSensitivity: .public,
                items: [ResearchVaultContextItem(
                    citation: VaultWireFixture.citation(), heading: nil, excerpt: excerpt, score: 1
                )],
                truncated: true
            )
        }
        let small = try bundle(excerpt: "ok").encodedForIPC()
        XCTAssertLessThanOrEqual(small.count, ResearchVaultIPCContract.maximumResponseBytes)
        XCTAssertEqual(
            try VaultWireFixture.decoder().decode(ResearchVaultContextBundle.self, from: small),
            bundle(excerpt: "ok")
        )
        let oversized = String(repeating: "x", count: ResearchVaultIPCContract.maximumResponseBytes + 1)
        XCTAssertThrowsError(try bundle(excerpt: oversized).encodedForIPC()) { error in
            XCTAssertTrue(error is ResearchVaultContextEncodingError)
        }
    }

    private func expectValidation<Value>(
        _ expected: ResearchVaultIPCValidationError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Value
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? ResearchVaultIPCValidationError, expected, file: file, line: line)
        }
    }

    private func fixture() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "pre-extraction-wire", withExtension: "json", subdirectory: "Fixtures"
        ))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func samples() throws -> [String: Any] {
        try XCTUnwrap(fixture()["samples"] as? [String: Any])
    }

    private func object(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }
}
