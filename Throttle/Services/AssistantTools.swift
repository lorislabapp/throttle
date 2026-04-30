import Foundation
import OSLog

/// In-band tool calls the assistant can issue inside its markdown
/// response, parsed and executed by Throttle. We don't use the
/// provider-native tool-use protocols (they differ across Anthropic's
/// API, claude.ai web, and Apple Intelligence) — instead the AI emits
/// fenced ```tool blocks like patches, Throttle parses + executes +
/// feeds results back, and any provider works the same way.
///
/// Format the AI emits:
///
///   ```tool
///   TOOL: read_file
///   PATH: /Users/kevin/.claude/settings.json
///   ```
///
/// or:
///
///   ```tool
///   TOOL: list_files
///   PATH: /Users/kevin/.claude/hooks/
///   ```
///
/// Throttle replies with a synthetic user message tagged `[tool_result
/// for read_file: …]` containing the bytes. The AI continues with that
/// new context.
enum AssistantTool: String, Sendable, CaseIterable {
    case readFile  = "read_file"
    case listFiles = "list_files"

    var description: String {
        switch self {
        case .readFile:
            return "Read the full contents of a file by absolute path. Returns the bytes (max 64 KB), or an error if the file is missing/binary/over the size cap."
        case .listFiles:
            return "List the immediate children of a directory. Returns names + sizes + last-modified."
        }
    }
}

struct AssistantToolCall: Sendable, Hashable {
    let tool: AssistantTool
    let path: String
}

enum AssistantToolCallParser {
    /// Pull all tool calls out of an assistant message. Returns them in
    /// order of appearance — the executor walks them sequentially.
    static func extract(from text: String) -> [AssistantToolCall] {
        guard let re = try? NSRegularExpression(
            pattern: "```tool\\s*\\n(.*?)\\n```",
            options: [.dotMatchesLineSeparators]
        ) else { return [] }
        var calls: [AssistantToolCall] = []
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        re.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let m = match,
                  m.numberOfRanges >= 2,
                  let bodyRange = Range(m.range(at: 1), in: text) else { return }
            let body = String(text[bodyRange])
            if let call = parseBody(body) {
                calls.append(call)
            }
        }
        return calls
    }

    private static func parseBody(_ body: String) -> AssistantToolCall? {
        var toolName: String?
        var path: String?
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("TOOL:") {
                toolName = String(s.dropFirst("TOOL:".count)).trimmingCharacters(in: .whitespaces)
            } else if s.hasPrefix("PATH:") {
                path = String(s.dropFirst("PATH:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let toolName, let tool = AssistantTool(rawValue: toolName),
              let path, !path.isEmpty else { return nil }
        return AssistantToolCall(tool: tool, path: path)
    }
}

/// Executes parsed tool calls with safety guardrails: never escape the
/// user's home directory, never return more than 64 KB of bytes, never
/// follow weird symlinks. Result text is what we feed back to the AI as
/// the next user-role message.
enum AssistantToolExecutor {
    private static let logger = Logger(subsystem: "com.lorislab.throttle", category: "AssistantTool")
    private static let maxFileSize = 64 * 1024
    private static let maxListEntries = 200

    static func execute(_ call: AssistantToolCall) -> String {
        let expanded = (call.path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)

        // Soft sandbox: refuse if the path resolves outside ~/.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard url.path.hasPrefix(home) else {
            return "Error: refusing to access \(url.path) — Throttle's assistant only reads files under your home directory."
        }

        switch call.tool {
        case .readFile:
            return readFile(url: url)
        case .listFiles:
            return listFiles(url: url)
        }
    }

    private static func readFile(url: URL) -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "Error: \(url.path) does not exist."
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else {
            return "Error: cannot stat \(url.path)."
        }
        if size > maxFileSize {
            return "Error: \(url.path) is \(size) bytes which exceeds the 64 KB tool cap. Read smaller files or ask the user to paste the relevant section."
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return "Error: \(url.path) is not UTF-8 readable (likely binary)."
        }
        logger.info("read_file \(url.path, privacy: .public) (\(size) bytes)")
        return "[\(url.path), \(size) bytes]\n\(text)"
    }

    private static func listFiles(url: URL) -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "Error: \(url.path) does not exist."
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "Error: cannot list \(url.path)."
        }
        let limited = Array(entries.prefix(maxListEntries))
        let isoFmt = ISO8601DateFormatter()
        var lines: [String] = ["[\(url.path), \(entries.count) entries\(entries.count > maxListEntries ? " — showing first \(maxListEntries)" : "")]"]
        for entry in limited.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let mtime = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map { isoFmt.string(from: $0) } ?? "?"
            let suffix = isDir ? "/" : ""
            lines.append("\(entry.lastPathComponent)\(suffix)  \(size)b  \(mtime)")
        }
        return lines.joined(separator: "\n")
    }
}
