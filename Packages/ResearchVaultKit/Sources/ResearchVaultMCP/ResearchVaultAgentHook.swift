import CryptoKit
import Darwin
import Foundation
import ResearchVaultIngestion
import ResearchVaultModel

public enum ResearchVaultAgentHookError: Error, Equatable, Sendable {
    case inputTooLarge
    case invalidInput
    case unsupportedEvent
    case missingParentAgent
    case unsafeInbox
    case unsafeTranscript
    case writeFailed
}

public struct ResearchVaultAgentHookResult: Codable, Equatable, Sendable {
    public let receiptID: String
    public let status: String
    public let fileName: String
}

/// Converts bounded Stop/SubagentStop/SessionEnd events into sealed receipt
/// candidates. It never approves or imports them. The owner-side inbox scanner
/// is the only consumer, and that scanner places all candidates in quarantine.
public struct ResearchVaultAgentHook: Sendable {
    public static let maximumInputBytes = 1_048_576
    public static let maximumTranscriptBytes = 8 * 1024 * 1024

    public init() {}

    public func process(inputData: Data, inboxURL: URL) throws -> ResearchVaultAgentHookResult {
        guard inputData.count <= Self.maximumInputBytes else {
            throw ResearchVaultAgentHookError.inputTooLarge
        }
        let decoder = JSONDecoder()
        guard let input = try? decoder.decode(HookInput.self, from: inputData),
              !input.sessionID.isBlank,
              !input.agentID.isBlank,
              !input.projectKey.isBlank
        else {
            throw ResearchVaultAgentHookError.invalidInput
        }
        guard HookEvent(rawValue: input.hookEventName) != nil else {
            throw ResearchVaultAgentHookError.unsupportedEvent
        }
        if input.hookEventName == HookEvent.subagentStop.rawValue,
           input.parentAgentID?.isBlank != false {
            throw ResearchVaultAgentHookError.missingParentAgent
        }

        let transcriptSource = try input.transcriptPath.map(Self.transcriptSource)
        let sources = input.sources ?? transcriptSource.map { [$0] } ?? []
        let findings = input.findings ?? [ResearchFinding(
            claim: "Agent research output requires owner review before it can become evidence.",
            status: .hypothesis,
            evidenceIDs: []
        )]
        let eventDigest = SHA256.hash(data: inputData)
        let receiptID = Self.uuidString(from: eventDigest)
        let receipt = try ResearchReceipt.seal(
            receiptID: receiptID,
            sessionID: input.sessionID,
            agentID: input.agentID,
            parentAgentID: input.parentAgentID,
            projectKey: input.projectKey,
            question: String((input.question ?? "Review agent research candidate").prefix(16384)),
            findings: findings,
            sources: sources,
            openQuestions: input.openQuestions ?? [],
            sensitivity: input.sensitivity ?? .internal,
            createdAt: Date(timeIntervalSince1970: Double(input.occurredAtMS ?? 0) / 1000)
        )
        return try Self.write(receipt: receipt, inboxURL: inboxURL)
    }

    private static func transcriptSource(path: String) throws -> ResearchSource {
        guard !path.isBlank, path.utf8.count <= 16384 else {
            throw ResearchVaultAgentHookError.unsafeTranscript
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ResearchVaultAgentHookError.unsafeTranscript }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= Self.maximumTranscriptBytes
        else {
            throw ResearchVaultAgentHookError.unsafeTranscript
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard data.count == metadata.st_size else {
            throw ResearchVaultAgentHookError.unsafeTranscript
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ResearchSource(
            id: "transcript",
            kind: .transcript,
            locator: path,
            observedAt: Date(timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec)),
            sha256: hash
        )
    }

    private static func write(
        receipt: ResearchReceipt,
        inboxURL: URL
    ) throws -> ResearchVaultAgentHookResult {
        try FileManager.default.createDirectory(
            at: inboxURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let values = try inboxURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ResearchVaultAgentHookError.unsafeInbox
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let payload = try encoder.encode(receipt)
        let fileName = receipt.receiptID + ResearchReceiptInbox.fileSuffix
        let destination = inboxURL.appendingPathComponent(fileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: destination.path) {
            return try existingResult(receipt: receipt, payload: payload, destination: destination)
        }
        let temporary = inboxURL.appendingPathComponent("." + receipt.receiptID + ".partial-" + UUID().uuidString)
        return try writeNew(
            receipt: receipt,
            payload: payload,
            fileName: fileName,
            temporary: temporary,
            destination: destination
        )
    }

    private static func existingResult(
        receipt: ResearchReceipt,
        payload: Data,
        destination: URL
    ) throws -> ResearchVaultAgentHookResult {
        guard (try? Data(contentsOf: destination)) == payload else {
            throw ResearchVaultAgentHookError.writeFailed
        }
        return ResearchVaultAgentHookResult(
            receiptID: receipt.receiptID,
            status: "already_present",
            fileName: destination.lastPathComponent
        )
    }

    private static func writeNew(
        receipt: ResearchReceipt,
        payload: Data,
        fileName: String,
        temporary: URL,
        destination: URL
    ) throws -> ResearchVaultAgentHookResult {
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ResearchVaultAgentHookError.writeFailed }
        var writeSucceeded = false
        defer {
            close(descriptor)
            if !writeSucceeded { unlink(temporary.path) }
        }
        let wroteAll = payload.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return payload.isEmpty }
            var offset = 0
            while offset < payload.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), payload.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        guard wroteAll, fsync(descriptor) == 0 else {
            throw ResearchVaultAgentHookError.writeFailed
        }
        if link(temporary.path, destination.path) != 0 {
            unlink(temporary.path)
            writeSucceeded = true
            return try existingResult(receipt: receipt, payload: payload, destination: destination)
        }
        unlink(temporary.path)
        writeSucceeded = true
        return ResearchVaultAgentHookResult(
            receiptID: receipt.receiptID,
            status: "candidate_written",
            fileName: fileName
        )
    }

    private static func uuidString(from digest: SHA256.Digest) -> String {
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = uuid_t(
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuid).uuidString.lowercased()
    }
}

private enum HookEvent: String, Codable {
    case stop = "Stop"
    case subagentStop = "SubagentStop"
    case sessionEnd = "SessionEnd"
}

private struct HookInput: Decodable {
    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionID = "session_id"
        case agentID = "agent_id"
        case parentAgentID = "parent_agent_id"
        case projectKey = "project_key"
        case question, findings, sources
        case openQuestions = "open_questions"
        case sensitivity
        case transcriptPath = "transcript_path"
        case occurredAtMS = "occurred_at_ms"
    }

    let hookEventName: String
    let sessionID: String
    let agentID: String
    let parentAgentID: String?
    let projectKey: String
    let question: String?
    let findings: [ResearchFinding]?
    let sources: [ResearchSource]?
    let openQuestions: [String]?
    let sensitivity: ResearchSensitivity?
    let transcriptPath: String?
    let occurredAtMS: Int64?
}

private extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
