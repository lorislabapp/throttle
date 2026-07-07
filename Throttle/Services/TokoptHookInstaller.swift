import Foundation

/// Installs / removes Throttle's PostToolUse(Bash) tokopt hook in
/// `~/.claude/settings.json`.
///
/// The hook command points at a thin shell **trampoline** we ship to
/// `~/.claude/throttle-hook.sh`, which in turn `exec`s the signed binary
/// (`<exec> --tokopt-hook`). The trampoline exists for ONE reason the direct
/// binary wiring can't cover: if the user deletes/moves Throttle.app (drag to
/// trash — no cleanup runs), the settings.json entry would keep invoking a
/// missing binary and inject a shell error into every Bash result. The
/// trampoline checks the binary exists first and otherwise no-ops (exit 0, no
/// output), so Claude Code keeps the original output untouched — fail-open even
/// when the app is gone. `reconcile()` can't help there; it lives in the app.
///
/// Reversible (backs up settings.json, splices out only OUR entry, deletes the
/// script), idempotent, and self-heals the binary path in the script on launch.
/// The user must restart Claude Code afterwards (hooks snapshot at session start).
enum TokoptHookInstaller {

    /// Stable marker identifying our (current) hook entry inside settings.json.
    static let marker = "throttle-hook.sh"
    /// Pre-3.2.45 entries wired the binary directly; used to migrate them.
    static let legacyMarker = "--tokopt-hook"

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var settingsFile: URL { home.appendingPathComponent(".claude/settings.json") }
    private static var scriptFile: URL { home.appendingPathComponent(".claude/throttle-hook.sh") }
    private static var backupsDir: URL { home.appendingPathComponent(".claude/throttle-backups", isDirectory: true) }

    /// settings.json command — a STABLE path (tilde-expanded by the shell that
    /// runs the hook, matching the proven statusline wiring). Because it never
    /// embeds the binary path, the settings entry itself never needs healing;
    /// only the script's `BIN=` line does.
    private static let hookCommand = "~/.claude/throttle-hook.sh"

    /// Absolute path to the currently-running Throttle binary (so the hook keeps
    /// working from /Applications, or DerivedData during development).
    private static var execPath: String { Bundle.main.executablePath ?? "/Applications/Throttle.app/Contents/MacOS/Throttle" }

    static func isInstalled() -> Bool {
        ourEntryIndices(in: postToolUseArray(readSettings())).isEmpty == false
    }

    @discardableResult
    static func install() throws -> Bool {
        try writeScript()
        var dict = readSettings() ?? [:]
        var hooks = dict["hooks"] as? [String: Any] ?? [:]
        var post = hooks["PostToolUse"] as? [[String: Any]] ?? []
        // Already present (current OR legacy) → don't duplicate; let reconcile
        // migrate a legacy entry and heal the script's binary path.
        guard ourEntryIndices(in: post).isEmpty else { return reconcile() }
        try backupSettings()
        let entry: [String: Any] = [
            "matcher": "Bash",
            "hooks": [[
                "type": "command",
                "command": hookCommand,
                "timeout": 10,
            ]],
        ]
        post.append(entry)
        hooks["PostToolUse"] = post
        dict["hooks"] = hooks
        try writeSettings(dict)
        return true
    }

    /// Launch-time self-heal (safe to call every launch):
    ///   1. rewrite the trampoline if missing or its `BIN=` path is stale
    ///      (Sparkle update / DerivedData → /Applications),
    ///   2. upgrade any legacy direct-binary settings entry to the trampoline.
    /// Writes/backs up only when something actually changed. No-op if not installed.
    @discardableResult
    static func reconcile() -> Bool {
        let scriptChanged = (try? writeScript()) ?? false
        guard var dict = readSettings(),
              var hooks = dict["hooks"] as? [String: Any],
              var post = hooks["PostToolUse"] as? [[String: Any]] else { return scriptChanged }
        var changed = false
        for i in post.indices {
            guard var cmds = post[i]["hooks"] as? [[String: Any]] else { continue }
            var entryChanged = false
            for j in cmds.indices {
                guard let c = cmds[j]["command"] as? String else { continue }
                // Legacy `<exec> --tokopt-hook` → the stable trampoline command.
                if c.contains(legacyMarker), !c.contains(marker) {
                    cmds[j]["command"] = hookCommand; entryChanged = true; changed = true
                }
            }
            if entryChanged { post[i]["hooks"] = cmds }
        }
        guard changed else { return scriptChanged }
        try? backupSettings()
        hooks["PostToolUse"] = post
        dict["hooks"] = hooks
        try? writeSettings(dict)
        return true
    }

    static func remove() throws {
        try? FileManager.default.removeItem(at: scriptFile)
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

    // MARK: - Trampoline script

    /// The trampoline body for a given binary path. Pure bash, clean-env safe
    /// (no `jq`, no PATH deps). Fail-open on every branch: disabled kill-switch,
    /// missing/non-executable binary → exit 0 with no stdout so Claude Code keeps
    /// the original Bash output. When the binary IS present, `exec` hands stdin
    /// straight through; `TokoptHook` then self-fail-opens on any internal doubt.
    static func scriptContents(execPath: String) -> String {
        """
        #!/bin/bash
        # Throttle tokopt trampoline — fail-open. On ANY doubt emit nothing and
        # exit 0 so Claude Code keeps the original Bash output unaltered. BIN is
        # rewritten by Throttle on launch (reconcile) when the app moves/updates.
        [ "${CLAUDE_DISABLE_TOKOPT_HOOKS:-}" = "1" ] && exit 0
        BIN='\(execPath)'
        [ -x "$BIN" ] || exit 0
        exec "$BIN" --tokopt-hook

        """
    }

    /// Write (or refresh) the trampoline. Returns true only when the on-disk
    /// content actually changed, so `reconcile()` stays a cheap no-op at rest.
    @discardableResult
    private static func writeScript() throws -> Bool {
        let desired = scriptContents(execPath: execPath)
        if let existing = try? String(contentsOf: scriptFile, encoding: .utf8), existing == desired {
            return false
        }
        let fm = FileManager.default
        try fm.createDirectory(at: scriptFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try desired.write(to: scriptFile, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptFile.path)
        return true
    }

    // MARK: - Helpers

    private static func postToolUseArray(_ dict: [String: Any]?) -> [[String: Any]] {
        (dict?["hooks"] as? [String: Any])?["PostToolUse"] as? [[String: Any]] ?? []
    }

    /// Indices of PostToolUse entries whose command carries our marker (current
    /// trampoline OR a legacy direct-binary entry awaiting migration).
    private static func ourEntryIndices(in post: [[String: Any]]) -> [Int] {
        var idxs: [Int] = []
        for (i, entry) in post.enumerated() {
            let cmds = (entry["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
            if cmds.contains(where: { $0.contains(marker) || $0.contains(legacyMarker) }) { idxs.append(i) }
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
