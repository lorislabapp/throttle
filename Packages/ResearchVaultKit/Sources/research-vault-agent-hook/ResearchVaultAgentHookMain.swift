import Foundation
import ResearchVaultMCP

@main
struct ResearchVaultAgentHookMain {
    static func main() {
        do {
            let inbox = try inboxURL(arguments: Array(CommandLine.arguments.dropFirst()))
            let input = try boundedStandardInput()
            let result = try ResearchVaultAgentHook().process(inputData: input, inboxURL: inbox)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try FileHandle.standardOutput.write(encoder.encode(result) + Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("research-vault-agent-hook: candidate rejected\n".utf8))
            exit(1)
        }
    }

    private static func inboxURL(arguments: [String]) throws -> URL {
        guard arguments.count == 2, arguments[0] == "--inbox", !arguments[1].isEmpty else {
            throw HookMainError.invalidArguments
        }
        return URL(fileURLWithPath: arguments[1], isDirectory: true)
    }

    private static func boundedStandardInput() throws -> Data {
        var data = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 64 * 1024), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= ResearchVaultAgentHook.maximumInputBytes else {
                throw HookMainError.inputTooLarge
            }
        }
        return data
    }
}

private enum HookMainError: Error { case invalidArguments; case inputTooLarge }
