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

    /// Heal a stale exec path in our `throttle-memory` entry without the user
    /// re-toggling — Throttle owns the `--mcp-server` path, so when the binary
    /// moves (a dev DerivedData build → /Applications, or a Sparkle update) the
    /// next launch repoints it. No-op if not installed or already current; backs
    /// up + writes only when the path actually changed. Restart Claude Code to
    /// pick it up. Mirrors TokoptHookInstaller.reconcile().
    @discardableResult
    static func reconcile() -> Bool {
        guard let dict = readJSON(), let healed = healing(dict, execPath: execPath) else { return false }
        try? backup()
        try? writeJSON(healed)
        return true
    }

    /// Pure: repoint `throttle-memory`'s command to `execPath`, or nil if no change
    /// is needed (not installed / already current). Heals a missing args too.
    static func healing(_ dict: [String: Any], execPath: String) -> [String: Any]? {
        guard var mcp = dict["mcpServers"] as? [String: Any],
              var entry = mcp[serverKey] as? [String: Any],
              (entry["command"] as? String) != execPath else { return nil }
        entry["command"] = execPath
        if (entry["args"] as? [String]) == nil { entry["args"] = ["--mcp-server"] }
        mcp[serverKey] = entry
        var out = dict; out["mcpServers"] = mcp
        return out
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
