import Foundation

/// Installs / removes the same `throttle-memory` MCP server for Claude Code and
/// Codex, pointing at Throttle's signed binary (`Throttle --mcp-server`). Both
/// writes are explicit, backed up and reversible; no provider transcript or
/// secret is copied between configurations.
enum TranscriptMemoryInstaller {

    static let serverKey = "throttle-memory"

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var globalConfig: URL { home.appendingPathComponent(".claude.json") }
    private static var backupsDir: URL { home.appendingPathComponent(".claude/throttle-backups", isDirectory: true) }
    private static var codexConfig: URL { home.appendingPathComponent(".codex/config.toml") }
    private static var codexBackupsDir: URL { home.appendingPathComponent(".codex/throttle-backups", isDirectory: true) }
    private static var execPath: String { Bundle.main.executablePath ?? "/Applications/Throttle.app/Contents/MacOS/Throttle" }
    private static let codexBegin = "# BEGIN THROTTLE MCP: throttle-memory"
    private static let codexEnd = "# END THROTTLE MCP: throttle-memory"

    static func isInstalled() -> Bool {
        isInstalledForClaude() || isInstalledForCodex()
    }

    static func isInstalledForClaude() -> Bool {
        ((readJSON()?["mcpServers"] as? [String: Any])?[serverKey]) != nil
    }

    static func isInstalledForCodex() -> Bool {
        guard let text = try? String(contentsOf: codexConfig, encoding: .utf8) else { return false }
        return text.contains(codexBegin) || text.contains("[mcp_servers.\(serverKey)]")
    }

    @discardableResult
    static func install() throws -> Bool {
        // Validate the Codex mutation before touching either provider. A same-name
        // unmanaged section is a hard conflict, not a reason to leave a partial
        // Claude-only installation behind.
        let oldCodex = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        let newCodex = try codexConfigInstalling(in: oldCodex, execPath: execPath)
        var changed = false
        var dict = readJSON() ?? [:]
        var mcp = dict["mcpServers"] as? [String: Any] ?? [:]
        if mcp[serverKey] == nil {
            try backup()
            mcp[serverKey] = ["command": execPath, "args": ["--mcp-server"]] as [String: Any]
            dict["mcpServers"] = mcp
            try writeJSON(dict)
            changed = true
        }
        if newCodex != oldCodex {
            try backupCodex()
            try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
            try newCodex.write(to: codexConfig, atomically: true, encoding: .utf8)
            changed = true
        }
        // Warm the index now so the first search isn't the slow full build.
        DispatchQueue.global(qos: .utility).async { _ = TranscriptIndex.reindex() }
        return changed
    }

    /// Heal a stale exec path in our `throttle-memory` entry without the user
    /// re-toggling — Throttle owns the `--mcp-server` path, so when the binary
    /// moves (a dev DerivedData build → /Applications, or a Sparkle update) the
    /// next launch repoints it. No-op if not installed or already current; backs
    /// up + writes only when the path actually changed. Restart Claude Code to
    /// pick it up. Mirrors TokoptHookInstaller.reconcile().
    @discardableResult
    static func reconcile() -> Bool {
        var changed = false
        if let dict = readJSON(), let healed = healing(dict, execPath: execPath) {
            try? backup()
            try? writeJSON(healed)
            changed = true
        }
        if let text = try? String(contentsOf: codexConfig, encoding: .utf8), text.contains(codexBegin),
           let healed = try? codexConfigInstalling(in: text, execPath: execPath), healed != text {
            try? backupCodex()
            try? healed.write(to: codexConfig, atomically: true, encoding: .utf8)
            changed = true
        }
        return changed
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
        if var dict = readJSON(), var mcp = dict["mcpServers"] as? [String: Any], mcp[serverKey] != nil {
            try backup()
            mcp.removeValue(forKey: serverKey)
            dict["mcpServers"] = mcp
            try writeJSON(dict)
        }
        if let old = try? String(contentsOf: codexConfig, encoding: .utf8) {
            let new = codexConfigRemovingManagedBlock(from: old)
            if new != old {
                try backupCodex()
                try new.write(to: codexConfig, atomically: true, encoding: .utf8)
            }
        }
    }

    enum Err: LocalizedError {
        case noConfig, codexServerConflict

        var errorDescription: String? {
            switch self {
            case .noConfig: return "the provider configuration could not be created"
            case .codexServerConflict:
                return "Codex already has an unmanaged mcp_servers.throttle-memory section; Throttle left both configurations unchanged"
            }
        }
    }

    static func codexConfigInstalling(in text: String, execPath: String) throws -> String {
        let escaped = execPath.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let block = """
        \(codexBegin)
        [mcp_servers.\(serverKey)]
        command = "\(escaped)"
        args = ["--mcp-server"]
        \(codexEnd)
        """
        if let begin = text.range(of: codexBegin),
           let end = text.range(of: codexEnd, range: begin.upperBound..<text.endIndex) {
            var out = text
            out.replaceSubrange(begin.lowerBound..<end.upperBound, with: block)
            return out
        }
        if text.contains("[mcp_servers.\(serverKey)]") { throw Err.codexServerConflict }
        let prefix = text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
        return prefix + (prefix.isEmpty ? "" : "\n") + block + "\n"
    }

    static func codexConfigRemovingManagedBlock(from text: String) -> String {
        guard let begin = text.range(of: codexBegin),
              let end = text.range(of: codexEnd, range: begin.upperBound..<text.endIndex) else { return text }
        var out = text
        var lower = begin.lowerBound
        // Installation separates its managed block with one extra newline. Remove
        // exactly that separator so uninstall restores the prior TOML byte-for-byte.
        if lower > out.startIndex {
            let previous = out.index(before: lower)
            if out[previous] == "\n" { lower = previous }
        }
        var upper = end.upperBound
        if upper < out.endIndex, out[upper] == "\n" { upper = out.index(after: upper) }
        out.removeSubrange(lower..<upper)
        return out.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

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

    private static func backupCodex() throws {
        try FileManager.default.createDirectory(at: codexBackupsDir, withIntermediateDirectories: true)
        let dest = codexBackupsDir.appendingPathComponent("config.toml-\(Int(Date().timeIntervalSince1970)).bak")
        if FileManager.default.fileExists(atPath: codexConfig.path) {
            try? FileManager.default.copyItem(at: codexConfig, to: dest)
        }
    }
}
