import Foundation
import ResearchVaultModel
import ResearchVaultXPCClient
import Testing

@Suite("Research Vault client Inbox reader")
struct ResearchVaultReceiptBatchReaderTests {
    @Test("reads canonical receipts deterministically and ignores unrelated JSON")
    func canonicalBatch() throws {
        let root = try inbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try receipt(id: "10000000-0000-4000-8000-000000000001")
        let second = try receipt(id: "10000000-0000-4000-8000-000000000002")
        try encode(second).write(to: root.appendingPathComponent("b.research-receipt.json"))
        try encode(first).write(to: root.appendingPathComponent("a.research-receipt.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("notes.json"))

        #expect(try ResearchVaultReceiptBatchReader().load(from: root) == [first, second])
    }

    @Test("rejects symlinks, duplicates, oversized files and oversized batches", arguments: [
        "symlink", "duplicate", "file-size", "count", "request-size",
    ])
    func failsClosed(kind: String) throws {
        let root = try inbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try receipt(id: "10000000-0000-4000-8000-000000000001")
        let firstData = try encode(first)
        switch kind {
        case "symlink":
            let target = root.appendingPathComponent("target.json")
            try firstData.write(to: target)
            let link = root.appendingPathComponent("a.research-receipt.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            #expect(throws: ResearchVaultReceiptBatchReaderError.entryNotRegularFile(link.lastPathComponent)) {
                try ResearchVaultReceiptBatchReader().load(from: root)
            }
        case "duplicate":
            try firstData.write(to: root.appendingPathComponent("a.research-receipt.json"))
            try firstData.write(to: root.appendingPathComponent("b.research-receipt.json"))
            #expect(throws: ResearchVaultReceiptBatchReaderError.duplicateReceiptID(first.receiptID)) {
                try ResearchVaultReceiptBatchReader().load(from: root)
            }
        case "file-size":
            try firstData.write(to: root.appendingPathComponent("a.research-receipt.json"))
            #expect(throws: ResearchVaultReceiptBatchReaderError.entryTooLarge("a.research-receipt.json")) {
                try ResearchVaultReceiptBatchReader(maximumReceiptBytes: 1).load(from: root)
            }
        case "count":
            try firstData.write(to: root.appendingPathComponent("a.research-receipt.json"))
            #expect(throws: ResearchVaultReceiptBatchReaderError.tooManyReceipts) {
                try ResearchVaultReceiptBatchReader(maximumReceiptCount: 0).load(from: root)
            }
        case "request-size":
            try firstData.write(to: root.appendingPathComponent("a.research-receipt.json"))
            #expect(throws: ResearchVaultReceiptBatchReaderError.requestTooLarge) {
                try ResearchVaultReceiptBatchReader(maximumRequestBytes: 1).load(from: root)
            }
        default:
            Issue.record("unknown case")
        }
    }

    private func inbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-vault-client-inbox-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func receipt(id: String) throws -> ResearchReceipt {
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
