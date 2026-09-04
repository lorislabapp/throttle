import Foundation
import ResearchVaultIngestion
@testable import Throttle
import XCTest

final class NotebookLMImportJobTests: XCTestCase {
    func testPauseRestartAndRerunAreIdempotent() async throws {
        let gateway = FakeNotebookLMGateway()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookLMImportJob-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let notebook = try XCTUnwrap(Self.notebook)

        let firstJob = NotebookLMImportJob(
            gateway: gateway,
            now: { Date(timeIntervalSince1970: 1_788_000_000) }
        )
        let paused = try await firstJob.run(
            notebook: notebook,
            stagingFolder: folder,
            maximumNewExports: 1
        )
        XCTAssertEqual(paused.phase, .paused)
        XCTAssertEqual(paused.completed, 1)

        let resumedJob = NotebookLMImportJob(
            gateway: gateway,
            now: { Date(timeIntervalSince1970: 1_788_000_000) }
        )
        let completed = try await resumedJob.run(notebook: notebook, stagingFolder: folder)
        XCTAssertEqual(completed.phase, .complete)
        XCTAssertEqual(completed.completed, 3)
        let exportsAfterResume = await gateway.exportedIndices()
        XCTAssertEqual(exportsAfterResume, [0, 1, 2])

        let rerunJob = NotebookLMImportJob(gateway: gateway)
        _ = try await rerunJob.run(notebook: notebook, stagingFolder: folder)
        let exportsAfterRerun = await gateway.exportedIndices()
        XCTAssertEqual(exportsAfterRerun, [0, 1, 2])

        let batch = try NotebookLMMigrationImporter(root: folder, projectKey: "job-test").load()
        XCTAssertEqual(batch.receipts.count, 3)
        XCTAssertEqual(batch.manifest.files.compactMap(\.sourceIndex), [0, 1, 2])
    }

    func testConflictingPayloadAndInvalidInventoryFailClosed() async throws {
        let gateway = FakeNotebookLMGateway()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookLMImportConflict-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let notebook = try XCTUnwrap(Self.notebook)
        let firstJob = NotebookLMImportJob(gateway: gateway)
        _ = try await firstJob.run(
            notebook: notebook,
            stagingFolder: folder,
            maximumNewExports: 1
        )
        let payload = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "md" }
        )
        try Data("tampered".utf8).write(to: payload)

        let resumedJob = NotebookLMImportJob(gateway: gateway)
        do {
            _ = try await resumedJob.run(notebook: notebook, stagingFolder: folder)
            XCTFail("Expected a conflicting checkpoint payload")
        } catch let error as NotebookLMImportJobError {
            XCTAssertEqual(error, .conflictingExport(0))
        }
    }

    func testMismatchedExportIdentityFailsClosed() async throws {
        let gateway = FakeNotebookLMGateway(exportedTitle: "Different source")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookLMImportIdentity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }

        do {
            _ = try await NotebookLMImportJob(gateway: gateway).run(
                notebook: try XCTUnwrap(Self.notebook),
                stagingFolder: folder,
                maximumNewExports: 1
            )
            XCTFail("Expected an export identity mismatch")
        } catch let error as NotebookLMImportJobError {
            XCTAssertEqual(error, .exportIdentityMismatch(0))
        }
    }

    func testPermutedExportOrderReconcilesAgainstCompleteInventory() async throws {
        let gateway = PermutedNotebookLMGateway()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookLMImportPermutation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }

        let result = try await NotebookLMImportJob(gateway: gateway).run(
            notebook: try XCTUnwrap(Self.notebook),
            stagingFolder: folder
        )
        XCTAssertEqual(result.phase, .complete)
        let batch = try NotebookLMMigrationImporter(root: folder, projectKey: "permutation").load()
        let titlesByExportIndex = batch.manifest.files
            .sorted { ($0.sourceIndex ?? -1) < ($1.sourceIndex ?? -1) }
            .compactMap(\.sourceTitle)
        XCTAssertEqual(titlesByExportIndex, ["Second", "Third", "First"])
    }

    func testGatewayCodecAcceptsOnlyBoundedTypedPayloads() throws {
        let notebooks = try JSONSerialization.data(withJSONObject: [
            "count": 1,
            "notebooks": [[
                "id": "01234567-89ab-4cde-8fab-0123456789ab",
                "name": "Throttle — SOTA 2026",
                "url": "https://notebook.google.com/notebook/01234567-89ab-4cde-8fab-0123456789ab",
                "sourceCount": 2
            ]]
        ])
        let sources = try JSONSerialization.data(withJSONObject: [
            "count": 2,
            "complete": true,
            "sources": [
                [
                    "notebookId": "01234567-89ab-4cde-8fab-0123456789ab",
                    "title": "First",
                    "sourceId": "a"
                ],
                [
                    "notebookId": "01234567-89ab-4cde-8fab-0123456789ab",
                    "title": "Second",
                    "sourceId": "b"
                ]
            ]
        ])
        let decodedNotebooks = try NotebookLMGatewayClient.decodeNotebooks(notebooks)
        XCTAssertEqual(decodedNotebooks.first?.title, "Throttle — SOTA 2026")
        XCTAssertEqual(decodedNotebooks.first?.sourceCount, 2)
        let decodedSources = try NotebookLMGatewayClient.decodeSources(sources)
        XCTAssertEqual(decodedSources.map(\.index), [0, 1])
        XCTAssertEqual(decodedSources.map(\.sourceID), ["a", "b"])
        XCTAssertEqual(
            try NotebookLMGatewayClient.decodeExport(Data("{\"markdown\":\"# Evidence\"}".utf8)),
            Data("# Evidence".utf8)
        )

        let oversized = Data(repeating: 0x61, count: NotebookLMGatewayClient.maximumResponseBytes + 1)
        XCTAssertThrowsError(try NotebookLMGatewayClient.decodeExport(oversized))
        let rejected = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 2,
            "error": ["message": "blocked"]
        ])
        XCTAssertThrowsError(try NotebookLMGatewayClient.unwrap(rejected))
    }

    func testGatewayCodecRejectsNegativeNotebookSourceCount() throws {
        let negativeSourceCount = try JSONSerialization.data(withJSONObject: [
            "notebooks": [[
                "id": "fixture-id",
                "name": "Fixture",
                "url": "https://notebook.google.com/notebook/01234567-89ab-4cde-8fab-0123456789ab",
                "sourceCount": -1
            ]]
        ])
        XCTAssertThrowsError(try NotebookLMGatewayClient.decodeNotebooks(negativeSourceCount))
    }

    func testGatewayCodecReadsOnlyBoundedExportRootReceipts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookLMExportReceipt-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let export = root.appendingPathComponent("source.txt")
        try Data("# Real export".utf8).write(to: export)
        let notebook = try XCTUnwrap(Self.notebook)
        let receipt = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "notebook": notebook.id,
            "title": "Throttle",
            "path": export.path
        ])

        let decoded = try NotebookLMGatewayClient.decodeExportReceipt(
            receipt,
            expectedNotebookURL: notebook.url,
            exportRoot: root
        )

        XCTAssertEqual(decoded.markdown, Data("# Real export".utf8))
        XCTAssertEqual(decoded.title, "Throttle")
        let outside = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "notebook": notebook.id,
            "title": "Throttle",
            "path": FileManager.default.temporaryDirectory.appendingPathComponent("outside.txt").path
        ])
        XCTAssertThrowsError(
            try NotebookLMGatewayClient.decodeExportReceipt(
                outside,
                expectedNotebookURL: notebook.url,
                exportRoot: root
            )
        )
    }

    func testGatewayStdioTransportUsesConfiguredEnvironmentWithoutExternalAccess() async throws {
        let responseData = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 2,
            "result": ["structuredContent": ["ok": true, "data": ["notebooks": [[
                "id": "fixture-id",
                "title": "Fixture",
                "url": "https://notebook.google.com/notebook/01234567-89ab-4cde-8fab-0123456789ab",
                "sourceCount": 4
            ]]]]]
        ])
        let response = try XCTUnwrap(String(data: responseData, encoding: .utf8))
        let script = """
        IFS= read -r initialize
        IFS= read -r initialized
        IFS= read -r call
        if [[ "$NLM_FIXTURE_SCOPE" == "local-only" ]]; then
          printf '%s\\n' '\(response)'
        else
          printf '%s\\n' '{"jsonrpc":"2.0","id":2,"error":{"message":"missing fixture scope"}}'
        fi
        """
        let config = MCPServerConfig(
            name: "fixture-notebooklm",
            transport: .stdio(
                command: "/bin/zsh",
                args: ["-c", script],
                env: ["NLM_FIXTURE_SCOPE": "local-only"]
            )
        )
        let client = try NotebookLMGatewayClient(config: config)

        let notebooks = try await client.listNotebooks()

        XCTAssertEqual(notebooks.map(\.title), ["Fixture"])
        XCTAssertEqual(notebooks.map(\.sourceCount), [4])
    }

    fileprivate static let notebook = URL(
        string: "https://notebook.google.com/notebook/01234567-89ab-4cde-8fab-0123456789ab"
    ).map {
        NotebookLMNotebookDescriptor(
            id: "01234567-89ab-4cde-8fab-0123456789ab",
            title: "Throttle",
            url: $0,
            sourceCount: 3
        )
    }
}

extension NotebookLMImportJobTests {
    func testRecordedLiveExportsReconcileWhenExplicitFixtureIsProvided() async throws {
        let fixturePath = ProcessInfo.processInfo.environment["THROTTLE_NLM_EXPORT_FIXTURE"]
            ?? "/tmp/throttle-notebooklm-live-export-fixture.json"
        guard FileManager.default.fileExists(atPath: fixturePath) else {
            throw XCTSkip("Set THROTTLE_NLM_EXPORT_FIXTURE for the explicit local-export integration")
        }
        let fixture = try JSONDecoder().decode(
            RecordedNotebookLMFixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: fixturePath))
        )
        let gateway = try RecordedNotebookLMGateway(fixture: fixture)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookLMLiveExportIntegration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }

        let result = try await NotebookLMImportJob(gateway: gateway).run(
            notebook: fixture.notebook,
            stagingFolder: folder
        )

        XCTAssertEqual(result.phase, .complete)
        XCTAssertEqual(result.completed, fixture.inventory.count)
        let batch = try NotebookLMMigrationImporter(root: folder, projectKey: "live-export").load()
        XCTAssertEqual(batch.receipts.count, fixture.inventory.count)
        XCTAssertEqual(Set(batch.manifest.files.compactMap(\.sourceTitle)), Set(fixture.inventory.map(\.title)))
    }
}

private actor FakeNotebookLMGateway: NotebookLMGatewayServing {
    private var exports: [Int] = []
    private let exportedTitle: String?

    init(exportedTitle: String? = nil) {
        self.exportedTitle = exportedTitle
    }

    func listNotebooks() async throws -> [NotebookLMNotebookDescriptor] {
        NotebookLMImportJobTests.notebook.map { [$0] } ?? []
    }

    func listSources(notebookURL: URL) async throws -> [NotebookLMSourceDescriptor] {
        [
            NotebookLMSourceDescriptor(index: 0, title: "Duplicate", sourceID: "a"),
            NotebookLMSourceDescriptor(index: 1, title: "Duplicate", sourceID: "b"),
            NotebookLMSourceDescriptor(index: 2, title: "Third", sourceID: "c")
        ]
    }

    func exportSource(notebookURL: URL, index: Int) async throws -> NotebookLMSourceExport {
        exports.append(index)
        return NotebookLMSourceExport(
            markdown: Data("# Source \(index)".utf8),
            title: exportedTitle
        )
    }

    func exportedIndices() -> [Int] { exports }
}

private actor PermutedNotebookLMGateway: NotebookLMGatewayServing {
    func listNotebooks() async throws -> [NotebookLMNotebookDescriptor] { [] }

    func listSources(notebookURL: URL) async throws -> [NotebookLMSourceDescriptor] {
        ["First", "Second", "Third"].enumerated().map {
            NotebookLMSourceDescriptor(index: $0.offset, title: $0.element, sourceID: nil)
        }
    }

    func exportSource(notebookURL: URL, index: Int) async throws -> NotebookLMSourceExport {
        let titles = ["Secondopen_in_new", "Third", "First"]
        return NotebookLMSourceExport(
            markdown: Data("# \(titles[index])".utf8),
            title: titles[index]
        )
    }
}

private struct RecordedNotebookLMFixture: Decodable {
    struct Export: Decodable {
        let index: Int
        let title: String
        let path: String
    }

    let notebook: NotebookLMNotebookDescriptor
    let inventory: [NotebookLMSourceDescriptor]
    let exports: [Export]
}

private actor RecordedNotebookLMGateway: NotebookLMGatewayServing {
    private let fixture: RecordedNotebookLMFixture
    private let exports: [Int: RecordedNotebookLMFixture.Export]
    private let exportRoot: URL

    init(fixture: RecordedNotebookLMFixture) throws {
        guard let first = fixture.exports.first else {
            throw NotebookLMGatewayClientError.invalidResponse
        }
        self.fixture = fixture
        exports = Dictionary(uniqueKeysWithValues: fixture.exports.map { ($0.index, $0) })
        exportRoot = URL(fileURLWithPath: first.path)
            .deletingLastPathComponent()
    }

    func listNotebooks() async throws -> [NotebookLMNotebookDescriptor] {
        [fixture.notebook]
    }

    func listSources(notebookURL: URL) async throws -> [NotebookLMSourceDescriptor] {
        fixture.inventory
    }

    func exportSource(notebookURL: URL, index: Int) async throws -> NotebookLMSourceExport {
        guard let export = exports[index] else {
            throw NotebookLMGatewayClientError.invalidResponse
        }
        let receipt = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "notebook": fixture.notebook.id,
            "title": export.title,
            "path": export.path
        ])
        return try NotebookLMGatewayClient.decodeExportReceipt(
            receipt,
            expectedNotebookURL: notebookURL,
            exportRoot: exportRoot
        )
    }
}
