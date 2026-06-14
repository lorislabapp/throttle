import Foundation

/// Full user-facing manager for Claude Code **output styles**.
///
/// Enumerates Claude Code's built-in styles plus every user style in
/// `~/.claude/output-styles/*.md`, reports and sets the active one (the
/// `outputStyle` key in `~/.claude/settings.json`, backed up before any edit),
/// and creates / edits / deletes custom styles from the app.
///
/// Distinct from `OutputStyleService`, which installs the single Autopilot
/// "Throttle Concise" style automatically. Once the user picks a style here we
/// set `userOverride`, and Autopilot then leaves `outputStyle` alone instead of
/// reinstalling concise over their choice.
///
/// Applies system-wide: the terminal AND the Cockpit's embedded `claude` both
/// read the same `outputStyle`.
enum OutputStyleManager {

    struct Style: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let description: String
        let isBuiltIn: Bool      // Claude Code ships it — no file, can't edit/delete
        let fileURL: URL?        // nil for built-ins
        var isActive: Bool = false
    }

    /// Claude Code's built-in styles. "Default" = the `outputStyle` key absent.
    static let builtIns: [(name: String, description: String)] = [
        ("Default", "Claude Code's standard engineering assistant."),
        ("Explanatory", "Explains its reasoning and design choices as it works."),
        ("Learning", "Teaches as it goes, with occasional hands-on asks."),
    ]

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var stylesDir: URL { home.appendingPathComponent(".claude/output-styles", isDirectory: true) }
    private static var settingsFile: URL { home.appendingPathComponent(".claude/settings.json") }
    private static var backupsDir: URL { home.appendingPathComponent(".claude/throttle-backups", isDirectory: true) }

    private static let overrideKey = "outputStyleUserOverride"
    /// True once the user has manually chosen a style — Autopilot then leaves
    /// `outputStyle` alone instead of reinstalling concise over their choice.
    static var userOverride: Bool {
        get { UserDefaults.standard.bool(forKey: overrideKey) }
        set { UserDefaults.standard.set(newValue, forKey: overrideKey) }
    }

    // MARK: - Enumerate

    static func activeName() -> String { currentOutputStyle() ?? "Default" }

    static func currentOutputStyle() -> String? {
        (readSettings()?["outputStyle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Built-ins first, then user styles (alphabetical), each flagged active.
    static func allStyles() -> [Style] {
        let active = activeName()
        var seen = Set(builtIns.map { $0.name })
        var out: [Style] = builtIns.map {
            Style(name: $0.name, description: $0.description, isBuiltIn: true,
                  fileURL: nil, isActive: $0.name == active)
        }
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: stylesDir, includingPropertiesForKeys: nil) {
            for url in files.filter({ $0.pathExtension == "md" })
                .sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
                let meta = parseFrontmatter(url)
                let name = meta.name ?? url.deletingPathExtension().lastPathComponent
                guard !seen.contains(name) else { continue }   // a user file shadowing a built-in name: keep the file
                seen.insert(name)
                out.append(Style(name: name,
                                 description: meta.description ?? "Custom output style.",
                                 isBuiltIn: false, fileURL: url, isActive: name == active))
            }
        }
        return out
    }

    /// Full markdown of a file-based style (for the editor). nil for built-ins.
    static func body(of style: Style) -> String? {
        guard let url = style.fileURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // Strip the leading frontmatter block so the editor shows just the body.
        if text.hasPrefix("---") {
            let parts = text.components(separatedBy: "\n---")
            if parts.count >= 2 {
                return parts.dropFirst().joined(separator: "\n---").drop(while: { $0 == "\n" || $0 == "-" }).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    // MARK: - Activate

    /// Point `outputStyle` at `name` (or clear it for "Default"). Backs up
    /// settings.json first. Marks the choice as a user override.
    static func setActive(_ name: String) throws {
        var dict = readSettings() ?? [:]
        _ = try? backupSettings()
        if name == "Default" { dict.removeValue(forKey: "outputStyle") }
        else { dict["outputStyle"] = name }
        try writeSettings(dict)
        userOverride = true
    }

    // MARK: - Create / edit

    /// Write (or overwrite at `fileURL`) a style file with YAML frontmatter.
    /// `keepCoding` adds `keep-coding-instructions: true` so Claude Code's
    /// engineering prompt is preserved and the style only shapes verbosity/voice.
    @discardableResult
    static func saveStyle(name: String, description: String, body: String,
                          keepCoding: Bool, fileURL: URL? = nil) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        let url = fileURL ?? stylesDir.appendingPathComponent("\(slug(name)).md")
        let content = """
        ---
        name: \(name)
        description: \(description)
        keep-coding-instructions: \(keepCoding)
        ---

        \(body.trimmingCharacters(in: .whitespacesAndNewlines))

        """
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Delete

    /// Delete a file-based style. Never deletes built-ins. If it was active,
    /// falls back to Default.
    static func delete(_ style: Style) throws {
        guard let url = style.fileURL else { return }
        if activeName() == style.name { try? setActive("Default") }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Templates (one-tap starting points for new styles)

    struct Template { let name: String; let description: String; let body: String; let keepCoding: Bool }

    static let templates: [Template] = [
        Template(name: "Concise",
                 description: "Answer-first, tight replies. The safe token saver.",
                 body: """
                 Be concise by default.

                 - Lead with the answer or result. No preamble, no restating the question.
                 - Tight bullets and short paragraphs over prose. Code beats explanation.
                 - Expand to full detail only when the task needs it (architecture, multi-file work, \
                 debugging) — then be as thorough as required.
                 - Don't narrate routine tool use.

                 Verbosity preference only — never reduces correctness, rigor, or depth.
                 """,
                 keepCoding: true),
        Template(name: "Caveman",
                 description: "Aggressive prose compression (fragment syntax, symbols, no filler). ~50–65% fewer output tokens.",
                 body: """
                 Compress every reply. Max signal, min tokens. Applies to PROSE only — never to code, \
                 commands, paths, or correctness.

                 RULES
                 - Fragment syntax: drop articles (a/the), subjects, linking verbs, conjunctions where \
                 meaning survives. "Bug in auth middleware" not "The issue is in the authentication middleware".
                 - Symbols over words: → (then/leads to), < > ≤ ≥ = ≠, & (and), w/ (with), b/c (because), vs, e.g., i.e.
                 - Kill filler: no preamble, no hedging, no courtesy, no restating the question, no explaining \
                 the obvious, no recap of what you just did.
                 - One idea per line. Line breaks replace sentences. Bullets over paragraphs.
                 - Abbreviate where unambiguous: fn, var, arg, req/resp, cfg, env, repo, dir, impl, ref.
                 - Preserve ALL technical specifics exactly: names, numbers, paths, signatures, error text.

                 NEVER compress: code blocks, terminal commands, file paths, API signatures, exact identifiers \
                 — those stay full and correct. Caveman is how you SPEAK, not how you reason: hard problem → \
                 full rigor, short words.
                 """,
                 keepCoding: true),
        Template(name: "Caveman Ultra",
                 description: "Maximum compression — telegraphic, expert reader assumed. ~70–85% fewer output tokens.",
                 body: """
                 Ultra-compress every reply. Fewest possible tokens. Assume an expert reader who wants the \
                 answer and nothing else. Often 1 line.

                 - Everything in Caveman mode, taken further: omit ALL scaffolding, intros, transitions, \
                 conclusions, and politeness.
                 - Lead with the answer/fix/verdict. Supporting detail only if load-bearing.
                 - Heavy symbols & fragments. No full sentences unless required for correctness.
                 - Numbers, paths, identifiers, code, commands: ALWAYS exact and complete.

                 Never sacrifice correctness or omit a fact for brevity. Reason fully internally; output minimal.
                 """,
                 keepCoding: true),
        Template(name: "Blank",
                 description: "Start from an empty body.",
                 body: "",
                 keepCoding: true),
    ]

    // MARK: - Frontmatter parse

    private static func parseFrontmatter(_ url: URL) -> (name: String?, description: String?) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (nil, nil) }
        var name: String?
        var desc: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(12) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l == "---" && (name != nil || desc != nil) { break }
            if let v = value(of: "name", in: l) { name = v }
            if let v = value(of: "description", in: l) { desc = v }
        }
        return (name, desc)
    }

    private static func value(of key: String, in line: String) -> String? {
        guard line.lowercased().hasPrefix("\(key):") else { return nil }
        let v = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    private static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        let mapped = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "style-\(Int(Date().timeIntervalSince1970))" : collapsed
    }

    // MARK: - settings.json IO (value-preserving, backed up)

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

    @discardableResult
    private static func backupSettings() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = backupsDir.appendingPathComponent("settings-\(stamp).json")
        if fm.fileExists(atPath: settingsFile.path) {
            try? fm.copyItem(at: settingsFile, to: dest)
        }
        return dest
    }
}
