import Foundation

/// Installs / removes the `throttle-memory` MCP server in the global Claude Code
/// config (`~/.claude.json` → `mcpServers`), pointing at Throttle's own binary
/// (`Throttle --mcp-server`). Lets Claude search the user's past sessions via the
/// `search_sessions` tool. Opt-in, backed up, reversible. Restart Claude Code to
/// load it.
enum TranscriptMemoryInstaller {

    static let serverKey = "throttle-memory"

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var globalConfig: URL { home.appendingPathComponent(".claude.json") }
    private static var backupsDir: URL { home.appendingPathComponent(".claude/throttle-backups", isDirectory: true) }
    private static var execPath: String { Bundle.main.executablePath ?? "/Applications/Throttle.app/Contents/MacOS/Throttle" }

    static func isInstalled() -> Bool {
        ((readJSON()?["mcpServers"] as? [String: Any])?[serverKey]) != nil
    }

    @discardableResult
    static func install() throws -> Bool {
        guard var dict = readJSON() else { throw Err.noConfig }
        var mcp = dict["mcpServers"] as? [String: Any] ?? [:]
        guard mcp[serverKey] == nil else { return false }
        try backup()
        mcp[serverKey] = ["command": execPath, "args": ["--mcp-server"]] as [String: Any]
        dict["mcpServers"] = mcp
        try writeJSON(dict)
        // Warm the index now so the first search isn't the slow full build.
        DispatchQueue.global(qos: .utility).async { _ = TranscriptIndex.reindex() }
        return true
    }

    static func remove() throws {
        guard var dict = readJSON(),
              var mcp = dict["mcpServers"] as? [String: Any], mcp[serverKey] != nil else { return }
        try backup()
        mcp.removeValue(forKey: serverKey)
        dict["mcpServers"] = mcp
        try writeJSON(dict)
    }

    enum Err: Error { case noConfig }

    private static func readJSON() -> [String: Any]? {
        guard let data = try? Data(contentsOf: globalConfig),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }
    private static func writeJSON(_ dict: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: globalConfig, options: .atomic)
    }
    private static func backup() throws {
        try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        let dest = backupsDir.appendingPathComponent("claude.json-\(Int(Date().timeIntervalSince1970)).bak")
        if FileManager.default.fileExists(atPath: globalConfig.path) { try? FileManager.default.copyItem(at: globalConfig, to: dest) }
    }
}
