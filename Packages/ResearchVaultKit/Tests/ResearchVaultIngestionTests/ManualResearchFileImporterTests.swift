import Foundation
import ResearchVaultIngestion
import Testing

@Suite("Manual research file importer")
struct ManualResearchFileImporterTests {
    @Test("selected files become deterministic OPEN receipts without absolute paths")
    func selectedFilesBecomeQuarantinableReceipts() throws {
        let root = try fixture("deterministic")
        defer { try? FileManager.default.removeItem(at: root) }
        let markdown = root.appendingPathComponent("study.md")
        let text = root.appendingPathComponent("notes.txt")
        try Data("# Study\nVerified only after review.".utf8).write(to: markdown)
        try Data("Manual notes".utf8).write(to: text)

        let first = try ManualResearchFileImporter(
            files: [markdown, text],
            projectKey: "throttle"
        ).load()
        let second = try ManualResearchFileImporter(
            files: [text, markdown],
            projectKey: "throttle"
        ).load()

        #expect(first.receipts.count == 2)
        #expect(first.files.map(\.name) == ["notes.txt", "study.md"])
        #expect(first.aggregateSHA256 == second.aggregateSHA256)
        #expect(first.receipts.map(\.receiptID) == second.receipts.map(\.receiptID))
        #expect(first.receipts.flatMap(\.findings).allSatisfy { $0.status == .open })
        #expect(first.receipts.allSatisfy { $0.sensitivity == .confidential })
        #expect(first.receipts.flatMap(\.sources).allSatisfy {
            $0.locator.hasPrefix("manual-import/") && !$0.locator.contains(root.path)
        })
    }

    @Test("changed content changes the receipt identity and aggregate hash")
    func changedContentChangesIdentity() throws {
        let root = try fixture("changed")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("research.md")
        try Data("version one".utf8).write(to: file)
        let first = try ManualResearchFileImporter(files: [file], projectKey: "throttle").load()
        try Data("version two".utf8).write(to: file)
        let second = try ManualResearchFileImporter(files: [file], projectKey: "throttle").load()

        #expect(first.aggregateSHA256 != second.aggregateSHA256)
        #expect(first.receipts.map(\.receiptID) != second.receipts.map(\.receiptID))
    }

    @Test("unsupported, linked and oversized files fail closed", arguments: [
        "unsupported", "symlink", "oversized"
    ])
    func unsafeSelectionFailsClosed(kind: String) throws {
        let root = try fixture(kind)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected: URL
        switch kind {
        case "unsupported":
            selected = root.appendingPathComponent("research.bin")
            try Data("research".utf8).write(to: selected)
            #expect(throws: ManualResearchFileImportError.unsupportedExtension("research.bin")) {
                _ = try ManualResearchFileImporter(files: [selected], projectKey: "throttle").load()
            }
            return
        case "symlink":
            let source = root.appendingPathComponent("source.md")
            try Data("research".utf8).write(to: source)
            selected = root.appendingPathComponent("linked.md")
            try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: source)
            #expect(throws: ManualResearchFileImportError.unsafeEntry("linked.md")) {
                _ = try ManualResearchFileImporter(files: [selected], projectKey: "throttle").load()
            }
            return
        case "oversized":
            selected = root.appendingPathComponent("large.txt")
            try Data(
                repeating: 0x61,
                count: ManualResearchFileImporter.maximumDocumentBytes + 1
            ).write(to: selected)
            #expect(throws: ManualResearchFileImportError.documentTooLarge("large.txt")) {
                _ = try ManualResearchFileImporter(files: [selected], projectKey: "throttle").load()
            }
            return
        default:
            Issue.record("unexpected test case")
            return
        }
    }

    @Test("invalid project key and empty selection fail closed")
    func invalidInputsFailClosed() throws {
        #expect(throws: ManualResearchFileImportError.invalidProjectKey) {
            _ = try ManualResearchFileImporter(files: [], projectKey: "Not Valid")
        }
        #expect(throws: ManualResearchFileImportError.emptySelection) {
            _ = try ManualResearchFileImporter(files: [], projectKey: "throttle").load()
        }
    }

    private func fixture(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualResearchImport-" + name + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
