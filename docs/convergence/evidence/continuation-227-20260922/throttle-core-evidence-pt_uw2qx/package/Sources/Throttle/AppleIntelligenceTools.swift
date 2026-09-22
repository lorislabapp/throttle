import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Native provider adapters use the same controller-owned project boundary.
#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct ReadFileToolArguments: Sendable {
    @Guide(description: "UTF-8 file path relative to the selected project.")
    let path: String
}

@available(macOS 26.0, *)
@Generable
struct ListFilesToolArguments: Sendable {
    @Guide(description: "Directory relative to the selected project, or . for its root.")
    let path: String
}

@available(macOS 26.0, *)
struct ReadFileTool: Tool {
    let scope: AssistantProjectTools
    let name = AssistantTool.readFile.rawValue
    let description = AssistantTool.readFile.description

    func call(arguments: ReadFileToolArguments) async throws -> String {
        let call = AssistantToolCall(tool: .readFile, path: arguments.path)
        return scope.execute(call)
    }
}

@available(macOS 26.0, *)
struct ListFilesTool: Tool {
    let scope: AssistantProjectTools
    let name = AssistantTool.listFiles.rawValue
    let description = AssistantTool.listFiles.description

    func call(arguments: ListFilesToolArguments) async throws -> String {
        let call = AssistantToolCall(tool: .listFiles, path: arguments.path)
        return scope.execute(call)
    }
}

@available(macOS 26.0, *)
@Generable
struct SearchFilesToolArguments: Sendable {
    @Guide(description: "Directory relative to the selected project, or . for its root.")
    let path: String
    @Guide(description: "Literal text to search, at most 256 characters.")
    let query: String
}

@available(macOS 26.0, *)
struct SearchFilesTool: Tool {
    let scope: AssistantProjectTools
    let name = AssistantTool.searchFiles.rawValue
    let description = AssistantTool.searchFiles.description

    func call(arguments: SearchFilesToolArguments) async throws -> String {
        scope.execute(AssistantToolCall(tool: .searchFiles, path: arguments.path, query: arguments.query))
    }
}
#endif
