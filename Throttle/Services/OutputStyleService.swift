import Foundation

/// Installs a global Claude Code **output style** that makes every session's
/// replies concise — system-wide (terminal + the Cockpit's embedded `claude`),
/// unlike Caveman which only shapes Throttle's own in-app Assistant.
///
/// Mechanism (confirmed against current Claude Code docs):
///   • a markdown file at `~/.claude/output-styles/<stem>.md` with YAML
///     frontmatter; the body is APPENDED to the system prompt,
///   • `keep-coding-instructions: true` so Claude Code's built-in engineering
///     prompt is KEPT — we only add terseness, never blank the reasoning prompt,
///   • activation via the `outputStyle` key in `~/.claude/settings.json`
///     (the style's display name, case-sensitive).
/// Reversible: `remove()` deletes the file and clears the key (only if it's
/// still ours). The original settings.json is backed up before any edit.
enum OutputStyleService {

    static let styleName = "Throttle Concise"
    private static let fileStem = "throttle-concise"

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var stylesDir: URL { home.appendingPathComponent(".claude/output-styles", isDirectory: true) }
    private static var styleFile: URL { stylesDir.appendingPathComponent("\(fileStem).md") }
    private static var settingsFile: URL { home.appendingPathComponent(".claude/settings.json") }
    private static var backupsDir: URL { home.appendingPathComponent(".claude/throttle-backups", isDirectory: true) }

    /// The concise instructions. Mirrors the user's own "be concise by default"
    /// voice, but additive — coding instructions are kept.
    private static let body = """
    ---
    name: \(styleName)
    description: Throttle — concise, answer-first replies system-wide. Keeps engineering instructions; only adds terseness.
    keep-coding-instructions: true
    ---

    Be concise by default.

    - Lead with the answer or result. No preamble ("Of course!", "Great question"), no restating the question.
    - Prefer tight bullets and short paragraphs over long prose. Code beats explanation.
    - Expand to full detail only when the task genuinely needs it (architecture, multi-file work, debugging) — then be as thorough as required, but never pad a simple answer.
    - Do not narrate routine tool use. Report outcomes plainly.

    This is a formatting/verbosity preference only. It never reduces correctness, rigor, or the depth of reasoning and code — when a task needs depth, give it.
    """

    // MARK: - State

    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: styleFile.path) && (currentOutputStyle() == styleName)
    }

    static func currentOutputStyle() -> String? {
        guard let dict = readSettings() else { return nil }
        return dict["outputStyle"] as? String
    }

    // MARK: - Install / remove

    /// Write the style file and point `outputStyle` at it. Backs up settings.json
    /// first. Returns the previous `outputStyle` value (nil if unset) so the
    /// caller's ledger can restore it exactly on undo.
    @discardableResult
    static func install() throws -> (previousStyle: String?, settingsBackup: URL?) {
        let fm = FileManager.default
        try fm.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        try body.write(to: styleFile, atomically: true, encoding: .utf8)

        var dict = readSettings() ?? [:]
        let previous = dict["outputStyle"] as? String
        var backup: URL? = nil
        if previous != styleName {
            backup = try backupSettings()
            dict["outputStyle"] = styleName
            try writeSettings(dict)
        }
        return (previous, backup)
    }

    /// Reverse `install`: delete the style file and restore the previous
    /// `outputStyle` (or clear the key) — but only if the key is still ours, so
    /// we never clobber a style the user picked afterwards.
    static func remove(restorePreviousStyle previous: String? = nil) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: styleFile)

        guard var dict = readSettings() else { return }
        if (dict["outputStyle"] as? String) == styleName {
            _ = try? backupSettings()
            if let previous, previous != styleName {
                dict["outputStyle"] = previous
            } else {
                dict.removeValue(forKey: "outputStyle")
            }
            try writeSettings(dict)
        }
    }

    // MARK: - settings.json IO (value-preserving, backed up)

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func writeSettings(_ dict: [String: Any]) throws {
        // Pretty + stable so the file stays human-diffable. All values preserved;
        // only key order may change (Claude Code reads JSON order-independent),
        // and the original is backed up before any write.
        let data = try JSONSerialization.data(withJSONObject: dict,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsFile, options: .atomic)
    }

    private static func backupSettings() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = backupsDir.appendingPathComponent("settings-\(stamp).json")
        if fm.fileExists(atPath: settingsFile.path) {
            try fm.copyItem(at: settingsFile, to: dest)
        }
        return dest
    }
}
