@testable import Throttle
import XCTest

final class AssistantProjectToolsTests: XCTestCase {
    func testControllerRootBoundsAllOperationsAndProducesReceipts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("état de test.md")
        try "fixture needle".write(to: file, atomically: true, encoding: .utf8)
        let scope = AssistantProjectTools(projectPath: root.path)
        for call in [AssistantToolCall(tool: .readFile, path: "état de test.md"),
                     AssistantToolCall(tool: .readFile, path: file.resolvingSymlinksInPath().path),
                     AssistantToolCall(tool: .listFiles, path: "."),
                     AssistantToolCall(tool: .searchFiles, query: "needle")] {
            let result = scope.execute(call)
            XCTAssertTrue(result.contains("RECEIPT"), result)
        }
        for path in ["../outside", root.path + "-sibling/a", "/etc/hosts", "~/a", "a/..", ".env"] {
            for tool in [AssistantTool.readFile, .listFiles, .searchFiles] {
                XCTAssertTrue(AssistantProjectTools(projectPath: root.path)
                    .execute(.init(tool: tool, path: path, query: "x")).hasPrefix("Error:"))
            }
        }
    }

    func testCopiedScopeSharesRequestBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = AssistantProjectTools(projectPath: root.path)
        let otherAdapter = scope
        for _ in 0..<5 { XCTAssertTrue(scope.execute(.init(tool: .listFiles)).contains("RECEIPT")) }
        XCTAssertTrue(otherAdapter.execute(.init(tool: .listFiles)).contains("budget exhausted"))
    }

    func testMissingOrBroadRootNeverFallsBackToHome() {
        for root in [nil, "/", "relative", FileManager.default.homeDirectoryForCurrentUser.path] {
            XCTAssertTrue(AssistantProjectTools(projectPath: root)
                .execute(.init(tool: .listFiles)).contains("no selected project"))
        }
        XCTAssertTrue(AssistantToolExecutor.execute(.init(tool: .readFile, path: "/etc/hosts")).hasPrefix("Error:"))
    }

    func testNativeAdaptersShareProjectScopeWithoutInvokingAModel() async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try "native needle".write(to: root.appendingPathComponent("file.md"), atomically: true, encoding: .utf8)
            let scope = AssistantProjectTools(projectPath: root.path)
            let read = try await ReadFileTool(scope: scope).call(arguments: ReadFileToolArguments(path: "file.md"))
            let list = try await ListFilesTool(scope: scope).call(arguments: ListFilesToolArguments(path: "."))
            let search = try await SearchFilesTool(scope: scope)
                .call(arguments: SearchFilesToolArguments(path: ".", query: "needle"))
            XCTAssertTrue(read.contains("native needle"))
            XCTAssertTrue(list.contains("file.md"))
            XCTAssertTrue(search.contains("file.md:1:"))
            let denied = try await ReadFileTool(scope: scope).call(arguments: ReadFileToolArguments(path: "/etc/hosts"))
            XCTAssertTrue(denied.hasPrefix("Error:"))
        } else { throw XCTSkip("Native adapters require macOS 26") }
        #else
        throw XCTSkip("FoundationModels SDK unavailable")
        #endif
    }

    func testSearchParserAndAmbiguousFields() {
        let text = "```tool\nTOOL: search_files\nPATH: .\nQUERY: a b\n```"
        XCTAssertEqual(AssistantToolCallParser.extract(from: text),
                       [.init(tool: .searchFiles, path: ".", query: "a b")])
        XCTAssertTrue(AssistantToolCallParser.extract(from: "```tool\nTOOL: read_file\nPATH: a\nPATH: b\n```").isEmpty)
    }
}
