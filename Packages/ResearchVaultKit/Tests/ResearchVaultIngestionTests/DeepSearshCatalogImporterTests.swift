import CryptoKit
import Foundation
import ResearchVaultIngestion
import ResearchVaultModel
import Testing

@Suite("DeepSearsh catalog importer")
struct DeepSearshCatalogImporterTests {
    @Test("accepts a verified, scoped document and emits snapshot evidence")
    func verifiedImport() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.add(id: "dr-good", project: "throttle", text: "# Local research\nEvidence.")

        let importer = try DeepSearshCatalogImporter(root: fixture.root)
        let batch = try importer.load(projectKeys: ["throttle"])

        #expect(batch.documents.count == 1)
        #expect(batch.documents[0].documentID == "dr-good")
        #expect(batch.documents[0].content.contains("Evidence"))
        #expect(batch.documents[0].sensitivity == .internal)
        #expect(batch.evidence.scannedEntries == 1)
        #expect(batch.evidence.acceptedDocuments == 1)
        #expect(batch.evidence.catalogSHA256.count == 64)
    }

    @Test("filters projects before reading their document bytes")
    func projectFilter() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.add(id: "dr-other", project: "other", text: "secret")
        try FileManager.default.removeItem(at: fixture.documentURL(id: "dr-other", project: "other"))

        let batch = try DeepSearshCatalogImporter(root: fixture.root)
            .load(projectKeys: ["throttle"])
        #expect(batch.documents.isEmpty)
        #expect(batch.evidence.scannedEntries == 1)
    }

    @Test("scopes a document through secondary project references")
    func secondaryProjectReference() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.add(
            id: "dr-shared", project: "deepsearsh", text: "shared",
            projectRefs: ["deepsearsh", "throttle"]
        )
        let batch = try DeepSearshCatalogImporter(root: fixture.root)
            .load(projectKeys: ["throttle"])
        #expect(batch.documents.map(\.projectKey) == ["throttle"])
        #expect(batch.documents[0].origins == ["/origins/throttle.md"])
    }

    @Test("rejects traversal, symlinks, tampering, duplicates, oversize and public defaults", arguments: [
        "traversal", "symlink", "hash", "size", "duplicate", "oversize", "public",
    ])
    func hostileInputs(kind: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        switch kind {
        case "traversal":
            try fixture.addRaw(id: "dr-x", project: "throttle", path: "library/../outside.md", text: "x")
            #expect(throws: DeepSearshImportError.invalidLibraryPath("library/../outside.md")) {
                try DeepSearshCatalogImporter(root: fixture.root).load()
            }
        case "symlink":
            try fixture.add(id: "dr-x", project: "throttle", text: "x")
            let url = fixture.documentURL(id: "dr-x", project: "throttle")
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: fixture.root.appendingPathComponent("catalog.jsonl"))
            #expect(throws: DeepSearshImportError.documentOutsideLibrary("dr-x")) {
                try DeepSearshCatalogImporter(root: fixture.root).load()
            }
        case "hash":
            try fixture.add(id: "dr-x", project: "throttle", text: "x", hash: String(repeating: "0", count: 64))
            #expect(throws: DeepSearshImportError.hashMismatch("dr-x")) {
                try DeepSearshCatalogImporter(root: fixture.root).load()
            }
        case "size":
            try fixture.add(id: "dr-x", project: "throttle", text: "x", size: 2)
            #expect(throws: DeepSearshImportError.sizeMismatch("dr-x")) {
                try DeepSearshCatalogImporter(root: fixture.root).load()
            }
        case "duplicate":
            try fixture.add(id: "dr-x", project: "throttle", text: "x")
            try fixture.add(id: "dr-x", project: "throttle", text: "x")
            #expect(throws: DeepSearshImportError.duplicateDocumentID("dr-x")) {
                try DeepSearshCatalogImporter(root: fixture.root).load()
            }
        case "oversize":
            try fixture.add(id: "dr-x", project: "throttle", text: "xx")
            let importer = try DeepSearshCatalogImporter(root: fixture.root, maximumDocumentBytes: 1)
            #expect(throws: DeepSearshImportError.documentTooLarge("dr-x")) { try importer.load() }
        case "public":
            #expect(throws: DeepSearshImportError.unsafeDefaultSensitivity) {
                try DeepSearshCatalogImporter(root: fixture.root, defaultSensitivity: .public)
            }
        default:
            Issue.record("unknown case")
        }
    }
}

private final class Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-vault-ingestion-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("library", isDirectory: true), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("catalog.jsonl"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func documentURL(id: String, project: String) -> URL {
        root.appendingPathComponent("library/" + project + "/" + id + ".md")
    }

    func add(
        id: String,
        project: String,
        text: String,
        hash: String? = nil,
        size: Int? = nil,
        projectRefs: [String]? = nil
    ) throws {
        let path = "library/" + project + "/" + id + ".md"
        try addRaw(
            id: id, project: project, path: path, text: text, hash: hash, size: size,
            projectRefs: projectRefs
        )
    }

    func addRaw(
        id: String,
        project: String,
        path: String,
        text: String,
        hash: String? = nil,
        size: Int? = nil,
        projectRefs: [String]? = nil
    ) throws {
        let data = Data(text.utf8)
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url) }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let referencedProjects = projectRefs ?? [project]
        let references = referencedProjects.map { ["name": $0, "slug": $0] }
        let originRecords = referencedProjects.map {
            ["path": "/origins/" + $0 + ".md", "project": $0]
        }
        let record: [String: Any] = [
            "id": id, "title": id, "project": project, "project_slug": project,
            "category": "test",
            "library_path": path, "sha256": hash ?? digest, "size_bytes": size ?? data.count,
            "modified_utc": "2026-08-27T12:00:00.000000+00:00",
            "origins": originRecords.map { $0["path"]! },
            "origin_records": originRecords,
            "project_refs": references,
        ]
        let line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data("\n".utf8)
        let catalog = root.appendingPathComponent("catalog.jsonl")
        let handle = try FileHandle(forWritingTo: catalog)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}
