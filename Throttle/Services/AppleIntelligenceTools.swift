import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence (macOS 26+) `Tool` conformances that wire the
/// existing `AssistantToolExecutor` sandbox into FoundationModels' native
/// tool-calling protocol. Once these are passed to `LanguageModelSession`,
/// the on-device model invokes them directly via the framework's
/// `tool_use → tool_result` round-trip — no fenced ```tool block parsing.
///
/// The fenced block format is still kept as the lowest-common-denominator
/// for the Safari Bridge (claude.ai web strips `tool_use` content blocks
/// server-side) and as the wire format the existing `runAssistantTurn`
/// recursion drives. Apple Intelligence and the BYO Claude API key path
/// both have native tool support; the bridge is the only legacy.
///
/// Why the wrapping rather than reimplementing the sandbox: keeping a
/// single sandbox source-of-truth in `AssistantToolExecutor` means the
/// 64 KB cap, home-directory check, and credential deny semantics can't
/// drift between providers.
#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct ReadFileToolArguments: Sendable {
    @Guide(description: "Absolute filesystem path to a UTF-8 readable file (≤ 64 KB) under the user's home directory.")
    let path: String
}

@available(macOS 26.0, *)
@Generable
struct ListFilesToolArguments: Sendable {
    @Guide(description: "Absolute filesystem path to a directory under the user's home directory.")
    let path: String
}

@available(macOS 26.0, *)
struct ReadFileTool: Tool {
    let name = AssistantTool.readFile.rawValue
    let description = AssistantTool.readFile.description

    func call(arguments: ReadFileToolArguments) async throws -> String {
        let call = AssistantToolCall(tool: .readFile, path: arguments.path)
        return AssistantToolExecutor.execute(call)
    }
}

@available(macOS 26.0, *)
struct ListFilesTool: Tool {
    let name = AssistantTool.listFiles.rawValue
    let description = AssistantTool.listFiles.description

    func call(arguments: ListFilesToolArguments) async throws -> String {
        let call = AssistantToolCall(tool: .listFiles, path: arguments.path)
        return AssistantToolExecutor.execute(call)
    }
}
#endif
