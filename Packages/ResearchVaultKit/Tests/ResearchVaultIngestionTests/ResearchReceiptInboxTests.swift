import Foundation
import ResearchVaultIngestion
import ResearchVaultModel
import Testing

@Suite("Research receipt Finder inbox")
struct ResearchReceiptInboxTests {
    @Test("loads canonical receipts deterministically")
    func canonicalBatch() throws {
        let root = try inbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = try makeReceipt(id: "9c7117e9-0f9b-483a-9587-a992883f44cb")
        try encode(receipt).write(to: root.appendingPathComponent("a.research-receipt.json"))
        let first = try ResearchReceiptInbox(root: root).scan()
        let second = try ResearchReceiptInbox(root: root).scan()
        #expect(first.receipts == [receipt])
        #expect(first.snapshotSHA256 == second.snapshotSHA256)
        #expect(first.acceptedBytes > 0)
    }

    @Test("invalid and duplicated receipts block the whole batch", arguments: ["invalid", "duplicate", "oversize"])
    func failClosed(kind: String) throws {
        let root = try inbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = try makeReceipt(id: "9c7117e9-0f9b-483a-9587-a992883f44cb")
        switch kind {
        case "invalid":
            try Data("{}".utf8).write(to: root.appendingPathComponent("bad.research-receipt.json"))
            #expect(throws: ResearchReceiptInboxError.invalidReceipt("bad.research-receipt.json")) {
                try ResearchReceiptInbox(root: root).scan()
            }
        case "duplicate":
            let data = try encode(receipt)
            try data.write(to: root.appendingPathComponent("a.research-receipt.json"))
            try data.write(to: root.appendingPathComponent("b.research-receipt.json"))
            #expect(throws: ResearchReceiptInboxError.duplicateReceiptID("9c7117e9-0f9b-483a-9587-a992883f44cb")) {
                try ResearchReceiptInbox(root: root).scan()
            }
        case "oversize":
            try encode(receipt).write(to: root.appendingPathComponent("a.research-receipt.json"))
            #expect(throws: ResearchReceiptInboxError.entryTooLarge("a.research-receipt.json")) {
                try ResearchReceiptInbox(root: root, maximumReceiptBytes: 1).scan()
            }
        default: Issue.record("unknown case")
        }
    }

    private func inbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-receipt-inbox-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeReceipt(id: String) throws -> ResearchReceipt {
        try ResearchReceipt.seal(
            receiptID: id,
            sessionID: "session-a",
            agentID: "agent-a",
            projectKey: "throttle",
            question: "What changed?",
            findings: [],
            sources: [],
            sensitivity: .internal,
            createdAt: Date(timeIntervalSince1970: 1_787_832_000)
        )
    }

    private func encode(_ receipt: ResearchReceipt) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(receipt)
    }
}
