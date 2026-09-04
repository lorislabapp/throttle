import CryptoKit
import Foundation
import ResearchVaultIngestion
import Testing

@Suite("NotebookLM local migration importer")
struct NotebookLMMigrationImporterTests {
    @Test("double load is deterministic and ignores unsupported files")
    func doubleLoadIsDeterministic() throws {
        let root = try fixture("deterministic")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# Alpha".utf8).write(to: root.appendingPathComponent("a.md"))
        try Data("beta".utf8).write(to: root.appendingPathComponent("b.txt"))
        try Data("ignored".utf8).write(to: root.appendingPathComponent("ignored.bin"))

        let importer = try NotebookLMMigrationImporter(root: root, projectKey: "test-import")
        let first = try importer.load()
        let second = try importer.load()

        #expect(first.receipts.count == 2)
        #expect(first.manifest.files.map(\.relativePath) == ["a.md", "b.txt"])
        #expect(first.manifest.aggregateSHA256 == second.manifest.aggregateSHA256)
        #expect(first.receipts.map(\.receiptID) == second.receipts.map(\.receiptID))
        #expect(first.receipts.flatMap(\.findings).allSatisfy { $0.status == .open })
    }

    @Test("changed source changes aggregate and receipt identity")
    func changedSourceIsDetected() throws {
        let root = try fixture("changed")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.md")
        try Data("version one".utf8).write(to: file)
        let importer = try NotebookLMMigrationImporter(root: root, projectKey: "test-import")
        let first = try importer.load()
        try Data("version two".utf8).write(to: file)
        let second = try importer.load()

        #expect(first.manifest.aggregateSHA256 != second.manifest.aggregateSHA256)
        #expect(first.receipts.map(\.receiptID) != second.receipts.map(\.receiptID))
    }

    @Test("symlink and oversized supported files fail closed", arguments: ["symlink", "oversize"])
    func unsafeEntriesFailClosed(kind: String) throws {
        let root = try fixture(kind)
        defer { try? FileManager.default.removeItem(at: root) }
        switch kind {
        case "symlink":
            let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
            defer { try? FileManager.default.removeItem(at: outside) }
            try Data("outside".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("linked.md"),
                withDestinationURL: outside
            )
            #expect(throws: NotebookLMMigrationError.self) {
                _ = try NotebookLMMigrationImporter(root: root, projectKey: "test-import").load()
            }
        case "oversize":
            let bytes = Data(
                repeating: 0x61,
                count: NotebookLMMigrationImporter.maximumDocumentBytes + 1
            )
            try bytes.write(to: root.appendingPathComponent("large.txt"))
            #expect(throws: NotebookLMMigrationError.documentTooLarge("large.txt")) {
                _ = try NotebookLMMigrationImporter(root: root, projectKey: "test-import").load()
            }
        default:
            Issue.record("unexpected test case")
        }
    }

    @Test("sidecars bind full NotebookLM provenance and duplicate titles by index")
    func sidecarProvenanceIsBoundByIndex() throws {
        let root = try fixture("sidecars")
        defer { try? FileManager.default.removeItem(at: root) }
        let notebookURL = "https://notebook.google.com/notebook/01234567-89ab-4cde-8fab-0123456789ab"
        for index in 0 ... 1 {
            let payload = root.appendingPathComponent("\(index)--duplicate.md")
            let bytes = Data("content \(index)".utf8)
            try bytes.write(to: payload)
            try writeSidecar(
                for: payload,
                notebookURL: notebookURL,
                index: index,
                title: "Duplicate"
            )
        }

        let batch = try NotebookLMMigrationImporter(root: root, projectKey: "test-import").load()

        #expect(batch.receipts.count == 2)
        #expect(batch.manifest.files.map(\.sourceIndex) == [0, 1])
        #expect(batch.receipts.map(\.question) == [
            "Imported NotebookLM source: Duplicate [source 0]",
            "Imported NotebookLM source: Duplicate [source 1]"
        ])
        #expect(batch.receipts[0].sources[0].locator == notebookURL + "#source-index=0")
        #expect(batch.receipts[1].sources[0].locator == notebookURL + "#source-index=1")
    }

    @Test("tampered sidecar or duplicate source index fails closed")
    func invalidSidecarsFailClosed() throws {
        let root = try fixture("invalid-sidecar")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("0--a.md")
        let second = root.appendingPathComponent("1--b.md")
        try Data("a".utf8).write(to: first)
        try Data("b".utf8).write(to: second)
        let notebookURL = "https://notebook.google.com/notebook/01234567-89ab-4cde-8fab-0123456789ab"
        try writeSidecar(for: first, notebookURL: notebookURL, index: 0, title: "A")
        try writeSidecar(for: second, notebookURL: notebookURL, index: 0, title: "B")

        #expect(throws: NotebookLMMigrationError.self) {
            _ = try NotebookLMMigrationImporter(root: root, projectKey: "test-import").load()
        }

        try Data("tampered".utf8).write(to: second)
        #expect(throws: NotebookLMMigrationError.self) {
            _ = try NotebookLMMigrationImporter(root: root, projectKey: "test-import").load()
        }
    }

    private func writeSidecar(
        for payload: URL,
        notebookURL: String,
        index: Int,
        title: String
    ) throws {
        let bytes = try Data(contentsOf: payload)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let value = NotebookLMSourceProvenance(
            notebookURL: notebookURL,
            sourceIndex: index,
            title: title,
            exportedAt: Date(timeIntervalSince1970: 1_788_000_000),
            payloadSHA256: hash
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(
            to: URL(fileURLWithPath: payload.path + ".provenance.json"),
            options: [.atomic]
        )
    }

    private func fixture(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookLMMigration-" + name + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
