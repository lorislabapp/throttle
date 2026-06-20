import Foundation

/// Installs / removes Throttle's PostToolUse(Bash) tokopt hook in
/// `~/.claude/settings.json`. The hook command points at Throttle's own binary
/// (`<exec> --tokopt-hook`), so there is no separate helper to ship. Reversible
/// (backs up settings.json, splices out only OUR entry), idempotent. The user
/// must restart Claude Code afterwards (hooks snapshot at session start).
enum TokoptHookInstaller {

    /// Stable marker that identifies our hook entry inside settings.json.
    static let marker = "--tokopt-hook"

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var settingsFile: URL { home.appendingPathComponent(".claude/settings.json") }
    private static var backupsDir: URL { home.appendingPathComponent(".claude/throttle-backups", isDirectory: true) }

    /// Absolute path to the currently-running Throttle binary (so the hook keeps
    /// working from /Applications, or DerivedData during development).
    private static var execPath: String { Bundle.main.executablePath ?? "/Applications/Throttle.app/Contents/MacOS/Throttle" }

    static func isInstalled() -> Bool {
        ourEntryIndices(in: postToolUseArray(readSettings())).isEmpty == false
    }

    @discardableResult
    static func install() throws -> Bool {
        var dict = readSettings() ?? [:]
        var hooks = dict["hooks"] as? [String: Any] ?? [:]
        var post = hooks["PostToolUse"] as? [[String: Any]] ?? []
        // Already present → don't duplicate, but DO heal a stale exec path
        // (e.g. an old DerivedData build path after installing to /Applications).
        guard ourEntryIndices(in: post).isEmpty else { return reconcile() }
        try backupSettings()
        let entry: [String: Any] = [
            "matcher": "Bash",
            "hooks": [[
                "type": "command",
                "command": "'\(execPath)' \(marker)",
                "timeout": 10,
            ]],
        ]
        post.append(entry)
        hooks["PostToolUse"] = post
        dict["hooks"] = hooks
        try writeSettings(dict)
        return true
    }

    /// Heal a stale exec path in our hook entry without requiring the user to
    /// re-toggle — the running Throttle owns the `--tokopt-hook` path, so when the
    /// binary moves (DerivedData → /Applications, or a Sparkle update) the next
    /// launch repoints it. No-op if not installed or already current. Safe to call
    /// on every launch (writes + backs up only when the path actually changed).
    @discardableResult
    static func reconcile() -> Bool {
        guard var dict = readSettings(),
              var hooks = dict["hooks"] as? [String: Any],
              var post = hooks["PostToolUse"] as? [[String: Any]] else { return false }
        let want = "'\(execPath)' \(marker)"
        var changed = false
        for i in post.indices {
            guard var cmds = post[i]["hooks"] as? [[String: Any]] else { continue }
            var entryChanged = false
            for j in cmds.indices {
                if let c = cmds[j]["command"] as? String, c.contains(marker), c != want {
                    cmds[j]["command"] = want; entryChanged = true; changed = true
                }
            }
            if entryChanged { post[i]["hooks"] = cmds }
        }
        guard changed else { return false }
        try? backupSettings()
        hooks["PostToolUse"] = post
        dict["hooks"] = hooks
        try? writeSettings(dict)
        return true
    }

    static func remove() throws {
        guard var dict = readSettings(),
              var hooks = dict["hooks"] as? [String: Any],
              var post = hooks["PostToolUse"] as? [[String: Any]] else { return }
        let ours = ourEntryIndices(in: post)
        guard !ours.isEmpty else { return }
        try backupSettings()
        for idx in ours.sorted(by: >) { post.remove(at: idx) }
        if post.isEmpty { hooks.removeValue(forKey: "PostToolUse") } else { hooks["PostToolUse"] = post }
        if hooks.isEmpty { dict.removeValue(forKey: "hooks") } else { dict["hooks"] = hooks }
        try writeSettings(dict)
    }

    // MARK: - Helpers

    private static func postToolUseArray(_ dict: [String: Any]?) -> [[String: Any]] {
        (dict?["hooks"] as? [String: Any])?["PostToolUse"] as? [[String: Any]] ?? []
    }

    /// Indices of PostToolUse entries whose command carries our marker.
    private static func ourEntryIndices(in post: [[String: Any]]) -> [Int] {
        var idxs: [Int] = []
        for (i, entry) in post.enumerated() {
            let cmds = (entry["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
            if cmds.contains(where: { $0.contains(marker) }) { idxs.append(i) }
        }
        return idxs
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func writeSettings(_ dict: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: dict,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsFile, options: .atomic)
    }

    @discardableResult
    private static func backupSettings() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        let dest = backupsDir.appendingPathComponent("settings-\(Int(Date().timeIntervalSince1970)).json")
        if fm.fileExists(atPath: settingsFile.path) { try? fm.copyItem(at: settingsFile, to: dest) }
        return dest
    }
}
