import Foundation

/// Installs the **brevity hooks** — the reliable carrier for the "concise
/// replies" feature (research `docs/research/output-styles-caveman-2026-07-14.md`):
///
///   • `UserPromptSubmit` — injects a ONE-LINE "be brief" directive next to
///     every prompt. Per-turn, maximum recency, mechanically guaranteed —
///     unlike the output style, which is read once at session start (fixed
///     since Claude Code v2.1.73) and therefore invisible to sessions that
///     were already open when the style was installed.
///   • `SessionStart` with matcher `compact` — re-injects the directive right
///     after auto/manual compaction, exactly where a style's effect dilutes.
///
/// Both paths go through one script, `~/.claude/hooks/throttle-brevity.sh`,
/// gated on the same `~/.claude/throttle-concise` flag file the session-start
/// router uses — so the Settings toggle controls everything, and removing the
/// flag silences the hooks without touching settings.json.
///
/// Style interaction: the script self-mutes when a custom `outputStyle` other
/// than "Throttle Concise" is active — a user-picked voice (e.g. Caveman
/// Ultra) governs alone; the one-liner would only dilute it.
///
/// Reversible: `remove()` strips exactly our entries from settings.json
/// (backed up first) and deletes the script.
enum BrevityHookService {

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var hooksDir: URL { home.appendingPathComponent(".claude/hooks", isDirectory: true) }
    private static var scriptFile: URL { hooksDir.appendingPathComponent("throttle-brevity.sh") }
    private static var settingsFile: URL { home.appendingPathComponent(".claude/settings.json") }
    private static var backupsDir: URL { home.appendingPathComponent(".claude/throttle-backups", isDirectory: true) }

    /// settings.json hook command — $HOME form like the other Throttle hooks.
    private static let command = "$HOME/.claude/hooks/throttle-brevity.sh"

    /// One line ≈ 15 tokens per turn. "be brief" alone captures nearly all of
    /// the measured gain (HN 24×5 benchmark; drona23 SUMMARY.md).
    private static let script = """
    #!/usr/bin/env bash
    # Throttle brevity hook — UserPromptSubmit + SessionStart(compact).
    # Injects a one-line terseness directive per turn / after compaction.
    # Gated on ~/.claude/throttle-concise (Throttle Settings toggle).
    set -u

    [ "${CLAUDE_DISABLE_TOKOPT_HOOKS:-0}" = "1" ] && exit 0
    [ -f "$HOME/.claude/throttle-concise" ] || exit 0

    # Self-mute when a custom output style OTHER than Throttle Concise is active:
    # that style governs the reply voice alone; a weaker directive only dilutes it.
    if [ -f "$HOME/.claude/settings.json" ]; then
      STYLE=$(grep -Eo '"outputStyle"[[:space:]]*:[[:space:]]*"[^"]+"' "$HOME/.claude/settings.json" 2>/dev/null \\
              | sed -E 's/.*:[[:space:]]*"([^"]+)"/\\1/' || true)
      if [ -n "${STYLE:-}" ] && [ "$STYLE" != "Throttle Concise" ]; then
        exit 0
      fi
    fi

    DIRECTIVE="Be brief: lead with the answer, no preamble or recap; expand only when the task genuinely needs depth."

    INPUT=$(cat 2>/dev/null || true)
    if printf '%s' "$INPUT" | grep -Eq '"hook_event_name"[[:space:]]*:[[:space:]]*"SessionStart"'; then
      # Compact path (settings.json matcher restricts us to source=compact).
      # JSON additionalContext is the documented reliable channel here.
      printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\\n' "$DIRECTIVE"
    else
      # UserPromptSubmit: bare stdout is added as context beside the prompt.
      printf '%s\\n' "$DIRECTIVE"
    fi
    exit 0
    """

    // MARK: - State

    static func isInstalled() -> Bool {
        guard FileManager.default.fileExists(atPath: scriptFile.path),
              let dict = readSettings(),
              let hooks = dict["hooks"] as? [String: Any] else { return false }
        return containsOurCommand(hooks["UserPromptSubmit"]) && containsOurCommand(hooks["SessionStart"])
    }

    private static func containsOurCommand(_ groups: Any?) -> Bool {
        guard let groups = groups as? [[String: Any]] else { return false }
        for g in groups {
            for h in (g["hooks"] as? [[String: Any]]) ?? [] where (h["command"] as? String) == command {
                return true
            }
        }
        return false
    }

    // MARK: - Install / remove

    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        try script.write(to: scriptFile, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptFile.path)

        var dict = readSettings() ?? [:]
        var hooks = (dict["hooks"] as? [String: Any]) ?? [:]
        var changed = false

        if !containsOurCommand(hooks["UserPromptSubmit"]) {
            var groups = (hooks["UserPromptSubmit"] as? [[String: Any]]) ?? []
            groups.append(["hooks": [["type": "command", "command": command]]])
            hooks["UserPromptSubmit"] = groups
            changed = true
        }
        if !containsOurCommand(hooks["SessionStart"]) {
            var groups = (hooks["SessionStart"] as? [[String: Any]]) ?? []
            groups.append(["matcher": "compact",
                           "hooks": [["type": "command", "command": command]]])
            hooks["SessionStart"] = groups
            changed = true
        }
        if changed {
            _ = try? backupSettings()
            dict["hooks"] = hooks
            try writeSettings(dict)
        }
    }

    /// Strip exactly our entries; leave every other hook untouched. Groups left
    /// empty by the strip are dropped; an event key left without groups is removed.
    static func remove() throws {
        try? FileManager.default.removeItem(at: scriptFile)
        guard var dict = readSettings(),
              var hooks = dict["hooks"] as? [String: Any] else { return }
        var changed = false
        for event in ["UserPromptSubmit", "SessionStart"] {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            var newGroups: [[String: Any]] = []
            for var g in groups {
                var inner = (g["hooks"] as? [[String: Any]]) ?? []
                let before = inner.count
                inner.removeAll { ($0["command"] as? String) == command }
                if inner.count != before { changed = true }
                g["hooks"] = inner
                if !inner.isEmpty { newGroups.append(g) }
            }
            groups = newGroups
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        if changed {
            _ = try? backupSettings()
            if hooks.isEmpty { dict.removeValue(forKey: "hooks") } else { dict["hooks"] = hooks }
            try writeSettings(dict)
        }
    }

    // MARK: - settings.json IO (same value-preserving pattern as OutputStyleService)

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func writeSettings(_ dict: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: dict,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsFile, options: .atomic)
    }

    private static func backupSettings() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        let dest = backupsDir.appendingPathComponent("settings-\(Int(Date().timeIntervalSince1970)).json")
        if fm.fileExists(atPath: settingsFile.path) {
            try fm.copyItem(at: settingsFile, to: dest)
        }
        return dest
    }
}
