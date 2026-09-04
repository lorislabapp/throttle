import CryptoKit
import Foundation

public enum ResearchSensitivity: String, Codable, CaseIterable, Sendable, Comparable {
    case `public`
    case `internal`
    case confidential
    case restricted

    public var policyRank: Int {
        switch self {
        case .public: 0
        case .internal: 1
        case .confidential: 2
        case .restricted: 3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.policyRank < rhs.policyRank
    }
}

public enum ResearchEvidenceStatus: String, Codable, CaseIterable, Sendable {
    case verified = "VERIFIED"
    case supported = "SUPPORTED"
    case hypothesis = "HYPOTHESIS"
    case open = "OPEN"
    case contradicted = "CONTRADICTED"
    case stale = "STALE"
}

/// Human-review state of imported material. Rejection is not a stored state:
/// rejecting deletes the rows. Existing pre-v4 rows are grandfathered as
/// approved by the SQLCipher migration.
public enum ResearchReviewState: String, Codable, Sendable, CaseIterable {
    case quarantined
    case approved
}

public enum ResearchSourceKind: String, Codable, CaseIterable, Sendable {
    case url
    case file
    case repository
    case transcript
    case database
    case other
}

public struct ResearchSource: Codable, Equatable, Sendable {
    public let id: String
    public let kind: ResearchSourceKind
    public let locator: String
    public let observedAt: Date
    public let sha256: String

    public init(
        id: String,
        kind: ResearchSourceKind,
        locator: String,
        observedAt: Date,
        sha256: String
    ) {
        self.id = id
        self.kind = kind
        self.locator = locator
        self.observedAt = observedAt
        self.sha256 = sha256
    }
}

public struct ResearchFinding: Codable, Equatable, Sendable {
    public let claim: String
    public let status: ResearchEvidenceStatus
    public let evidenceIDs: [String]

    public init(claim: String, status: ResearchEvidenceStatus, evidenceIDs: [String]) {
        self.claim = claim
        self.status = status
        self.evidenceIDs = evidenceIDs
    }
}

public struct ResearchReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let receiptID: String
    public let sessionID: String
    public let agentID: String
    public let parentAgentID: String?
    public let projectKey: String
    public let question: String
    public let findings: [ResearchFinding]
    public let sources: [ResearchSource]
    public let openQuestions: [String]
    public let sensitivity: ResearchSensitivity
    public let createdAt: Date
    public let contentHash: String

    public init(
        schemaVersion: Int = ResearchReceipt.currentSchemaVersion,
        receiptID: String,
        sessionID: String,
        agentID: String,
        parentAgentID: String? = nil,
        projectKey: String,
        question: String,
        findings: [ResearchFinding],
        sources: [ResearchSource],
        openQuestions: [String] = [],
        sensitivity: ResearchSensitivity,
        createdAt: Date,
        contentHash: String
    ) {
        self.schemaVersion = schemaVersion
        self.receiptID = receiptID
        self.sessionID = sessionID
        self.agentID = agentID
        self.parentAgentID = parentAgentID
        self.projectKey = projectKey
        self.question = question
        self.findings = findings
        self.sources = sources
        self.openQuestions = openQuestions
        self.sensitivity = sensitivity
        self.createdAt = createdAt
        self.contentHash = contentHash
    }

    public static func seal(
        receiptID: String = UUID().uuidString.lowercased(),
        sessionID: String,
        agentID: String,
        parentAgentID: String? = nil,
        projectKey: String,
        question: String,
        findings: [ResearchFinding],
        sources: [ResearchSource],
        openQuestions: [String] = [],
        sensitivity: ResearchSensitivity,
        createdAt: Date = Date()
    ) throws -> ResearchReceipt {
        let payload = ResearchReceiptPayload(
            schemaVersion: currentSchemaVersion,
            receiptID: receiptID,
            sessionID: sessionID,
            agentID: agentID,
            parentAgentID: parentAgentID,
            projectKey: projectKey,
            question: question,
            findings: findings,
            sources: sources,
            openQuestions: openQuestions,
            sensitivity: sensitivity,
            createdAt: createdAt
        )
        let hash = try ReceiptCanonicalizer.hash(payload)
        let receipt = ResearchReceipt(payload: payload, contentHash: hash)
        try ResearchReceiptValidator.validate(receipt)
        return receipt
    }

    fileprivate var payload: ResearchReceiptPayload {
        ResearchReceiptPayload(
            schemaVersion: schemaVersion,
            receiptID: receiptID,
            sessionID: sessionID,
            agentID: agentID,
            parentAgentID: parentAgentID,
            projectKey: projectKey,
            question: question,
            findings: findings,
            sources: sources,
            openQuestions: openQuestions,
            sensitivity: sensitivity,
            createdAt: createdAt
        )
    }

    private init(payload: ResearchReceiptPayload, contentHash: String) {
        self.init(
            schemaVersion: payload.schemaVersion,
            receiptID: payload.receiptID,
            sessionID: payload.sessionID,
            agentID: payload.agentID,
            parentAgentID: payload.parentAgentID,
            projectKey: payload.projectKey,
            question: payload.question,
            findings: payload.findings,
            sources: payload.sources,
            openQuestions: payload.openQuestions,
            sensitivity: payload.sensitivity,
            createdAt: payload.createdAt,
            contentHash: contentHash
        )
    }
}

private struct ResearchReceiptPayload: Codable {
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
}

private enum ReceiptCanonicalizer {
    static func hash(_ payload: ResearchReceiptPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(payload)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ResearchReceiptValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidReceiptID
    case invalidProjectKey
    case emptyField(String)
    case valueTooLong(String)
    case duplicateSourceID(String)
    case invalidSHA256(sourceID: String)
    case missingEvidence(findingIndex: Int, evidenceID: String)
    case evidenceRequired(findingIndex: Int)
    case contentHashMismatch
}

public enum ResearchReceiptValidator {
    public static func validate(_ receipt: ResearchReceipt) throws {
        guard receipt.schemaVersion == ResearchReceipt.currentSchemaVersion else {
            throw ResearchReceiptValidationError.unsupportedSchemaVersion(receipt.schemaVersion)
        }
        guard UUID(uuidString: receipt.receiptID) != nil else {
            throw ResearchReceiptValidationError.invalidReceiptID
        }
        guard receipt.projectKey.range(
            of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#,
            options: .regularExpression
        ) != nil else {
            throw ResearchReceiptValidationError.invalidProjectKey
        }

        try require(receipt.sessionID, name: "sessionID", max: 512)
        try require(receipt.agentID, name: "agentID", max: 512)
        try require(receipt.question, name: "question", max: 16_384)
        if let parentAgentID = receipt.parentAgentID {
            try require(parentAgentID, name: "parentAgentID", max: 512)
        }

        var sourceIDs = Set<String>()
        for source in receipt.sources {
            try require(source.id, name: "source.id", max: 256)
            try require(source.locator, name: "source.locator", max: 16_384)
            guard sourceIDs.insert(source.id).inserted else {
                throw ResearchReceiptValidationError.duplicateSourceID(source.id)
            }
            guard isSHA256(source.sha256) else {
                throw ResearchReceiptValidationError.invalidSHA256(sourceID: source.id)
            }
        }

        for (index, finding) in receipt.findings.enumerated() {
            try require(finding.claim, name: "finding.claim", max: 32_768)
            if finding.status == .verified || finding.status == .supported {
                guard !finding.evidenceIDs.isEmpty else {
                    throw ResearchReceiptValidationError.evidenceRequired(findingIndex: index)
                }
            }
            for evidenceID in finding.evidenceIDs where !sourceIDs.contains(evidenceID) {
                throw ResearchReceiptValidationError.missingEvidence(
                    findingIndex: index,
                    evidenceID: evidenceID
                )
            }
        }

        let expectedHash = try ReceiptCanonicalizer.hash(receipt.payload)
        guard constantTimeEquals(receipt.contentHash, expectedHash) else {
            throw ResearchReceiptValidationError.contentHashMismatch
        }
    }

    private static func require(_ value: String, name: String, max: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResearchReceiptValidationError.emptyField(name)
        }
        guard value.utf8.count <= max else {
            throw ResearchReceiptValidationError.valueTooLong(name)
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}
