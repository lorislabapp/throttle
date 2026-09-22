import Foundation

/// Provider-neutral project tool calls. The controller supplies the root;
/// model arguments cannot select another project or grant execution rights.
enum AssistantTool: String, Sendable, CaseIterable {
    case readFile  = "read_file"
    case listFiles = "list_files"
    case searchFiles = "search_files"
    case bash      = "bash"

    var description: String {
        switch self {
        case .readFile:
            return "Read a bounded UTF-8 project file; sensitive paths and links are refused."
        case .listFiles: return "List bounded immediate entries relative to the selected project. Use . for its root."
        case .searchFiles: return "Search a literal string in bounded project text files, with source receipts."
        case .bash: return "Disabled. Generic shell text is not an authorized tool."
        }
    }
}

struct AssistantToolCall: Sendable, Hashable {
    let tool: AssistantTool
    /// Filesystem path for `read_file` / `list_files`. Empty for `bash`.
    let path: String
    /// Shell command string for `bash` (binary + space-joined args, no
    /// pipes/redirections/metacharacters). Empty for path-based tools.
    let command: String
    let query: String

    init(tool: AssistantTool, path: String = "", command: String = "", query: String = "") {
        self.tool = tool
        self.path = path
        self.command = command
        self.query = query
    }

    /// User-facing label for the tool-result card row.
    var displayLabel: String {
        switch tool {
        case .bash: return command
        default:    return path
        }
    }
}

enum AssistantToolCallParser {
    /// Pull all tool calls out of an assistant message. Returns them in
    /// order of appearance — the executor walks them sequentially.
    static func extract(from text: String) -> [AssistantToolCall] {
        guard let expression = try? NSRegularExpression(
            pattern: "```tool\\s*\\n(.*?)\\n```",
            options: [.dotMatchesLineSeparators]
        ) else { return [] }
        var calls: [AssistantToolCall] = []
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        expression.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match,
                  match.numberOfRanges >= 2,
                  let bodyRange = Range(match.range(at: 1), in: text) else { return }
            let body = String(text[bodyRange])
            if let call = parseBody(body) {
                calls.append(call)
            }
        }
        return calls
    }

    private static func parseBody(_ body: String) -> AssistantToolCall? {
        guard let fields = fields(in: body), let name = fields["TOOL"],
              let tool = AssistantTool(rawValue: name) else { return nil }
        let path = fields["PATH"]
        let query = fields["QUERY"]
        let command = fields["CMD"]
        switch tool {
        case .readFile, .listFiles:
            guard let path, !path.isEmpty else { return nil }
            return AssistantToolCall(tool: tool, path: path)
        case .searchFiles:
            guard let query, !query.isEmpty else { return nil }
            return AssistantToolCall(tool: tool, path: path ?? "", query: query)
        case .bash:
            guard let command, !command.isEmpty else { return nil }
            return AssistantToolCall(tool: tool, command: command)
        }
    }

    private static func fields(in body: String) -> [String: String]? {
        var fields: [String: String] = [:]
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard let colon = text.firstIndex(of: ":") else { return nil }
            let key = String(text[..<colon])
            guard ["TOOL", "PATH", "CMD", "QUERY"].contains(key), fields[key] == nil else { return nil }
            fields[key] = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return fields
    }

}

/// Legacy callers fail closed without a controller-selected project.
enum AssistantToolExecutor {
    static func execute(_ call: AssistantToolCall, projectPath: String? = nil) -> String {
        AssistantProjectTools(projectPath: projectPath).execute(call)
    }
}
