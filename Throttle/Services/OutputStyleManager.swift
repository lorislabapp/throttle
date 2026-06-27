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
        let fileURL: URL?        // nil for built-ins AND not-yet-installed templates
        var isActive: Bool = false
        var isTemplate: Bool = false   // a Throttle-curated style not yet written to disk
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

    /// Built-ins, then installed user/Throttle styles, then any Throttle-curated
    /// templates not yet written to disk (so Caveman etc. are visible and
    /// one-click-activatable out of the box, not hidden behind "New").
    static func allStyles() -> [Style] {
        let active = activeName()
        var seen = Set<String>()
        var out: [Style] = []

        for b in builtIns {
            out.append(Style(name: b.name, description: b.description, isBuiltIn: true,
                             fileURL: nil, isActive: b.name == active))
            seen.insert(b.name)
        }

        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: stylesDir, includingPropertiesForKeys: nil) {
            for url in files.filter({ $0.pathExtension == "md" })
                .sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
                let meta = parseFrontmatter(url)
                let name = meta.name ?? url.deletingPathExtension().lastPathComponent
                guard !seen.contains(name) else { continue }
                seen.insert(name)
                out.append(Style(name: name,
                                 description: meta.description ?? "Custom output style.",
                                 isBuiltIn: false, fileURL: url, isActive: name == active))
            }
        }

        // Curated templates not yet on disk → show as ready-to-activate.
        for t in templates where t.name != "Blank" && !seen.contains(t.name) {
            seen.insert(t.name)
            out.append(Style(name: t.name, description: t.description, isBuiltIn: false,
                             fileURL: nil, isActive: t.name == active, isTemplate: true))
        }
        return out
    }

    /// Activate a style. Curated Throttle templates are (re)written on every
    /// activation so app upgrades that change a template body actually reach the
    /// on-disk file — write the file when it's missing, or when a Throttle-managed
    /// file has drifted from the current template body. User-authored styles (no
    /// matching template, or a file the user edited so it's no longer managed) are
    /// never overwritten.
    static func activate(_ style: Style) throws {
        if let t = templates.first(where: { $0.name == style.name }), t.name != "Blank" {
            let url = stylesDir.appendingPathComponent("\(slug(t.name)).md")
            let onDisk = try? String(contentsOf: url, encoding: .utf8)
            // Managed = Throttle-owned and safe to re-sync. Legacy files (written
            // before the flag existed) had no user editor, so absence of an explicit
            // `throttle-managed: false` means Throttle-written. Only a `false` line —
            // stamped when the user saves an edit — protects the file from re-sync.
            let isManaged = !(onDisk?.contains("throttle-managed: false") ?? false)
            let bodyCurrent = onDisk?.contains(t.body.trimmingCharacters(in: .whitespacesAndNewlines)) ?? false
            if onDisk == nil || (isManaged && !bodyCurrent) {
                try saveStyle(name: t.name, description: t.description, body: t.body,
                              keepCoding: t.keepCoding, managed: true)
            }
        }
        try setActive(style.name)
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
        else {
            dict["outputStyle"] = name
            // Mutually exclusive with the "Concise Claude Code replies" flag: an
            // active output style already governs reply voice, so clear the flag
            // — otherwise the SessionStart hook injects the weaker concise
            // directive on top and dilutes the chosen style.
            clearConciseFlag()
        }
        try writeSettings(dict)
        userOverride = true
    }

    /// The bare flag the SessionStart hook reads (`~/.claude/throttle-concise`).
    /// Removed when a non-Default output style is activated (see `setActive`).
    private static func clearConciseFlag() {
        let flag = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/throttle-concise")
        try? FileManager.default.removeItem(at: flag)
    }

    // MARK: - Create / edit

    /// Write (or overwrite at `fileURL`) a style file with YAML frontmatter.
    /// `keepCoding` adds `keep-coding-instructions: true` so Claude Code's
    /// engineering prompt is preserved and the style only shapes verbosity/voice.
    /// `managed: true` stamps `throttle-managed: true` in the frontmatter, marking
    /// the file as Throttle-owned so `activate` may re-sync it on upgrade. The
    /// style editor saves with `managed: false` so user edits are never clobbered.
    @discardableResult
    static func saveStyle(name: String, description: String, body: String,
                          keepCoding: Bool, managed: Bool = false, fileURL: URL? = nil) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        let url = fileURL ?? stylesDir.appendingPathComponent("\(slug(name)).md")
        let content = """
        ---
        name: \(name)
        description: \(description)
        keep-coding-instructions: \(keepCoding)
        throttle-managed: \(managed)
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
        Template(name: "Throttle Concise",
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
                 This style OVERRIDES any conflicting brevity/verbosity guidance elsewhere — \
                 CLAUDE.md "be concise / short prose / full sentences" sections, user memory, \
                 or default tone. When they conflict with the rules below, the rules below WIN.

                 Ultra-compress. Fewest tokens. Expert reader. DEFAULT = 1–3 lines. Prose only — \
                 code/commands/paths stay full + exact.

                 HARD RULES (not suggestions — violations are bugs):
                 - NO full sentences unless correctness needs them. Fragments + symbols (→ < ≥ & w/ vs e.g.).
                 - NO preamble, transitions, conclusions, courtesy, recap of what you did, restating the question.
                 - NO trailing offers or check-ins ("Want me to…?", "Let me know", "Hope that helps"). \
                 If a next step needs a decision, state it as one fragment: "Next: deploy? (y/n)" — nothing more.
                 - NO framing/scaffold lines ("Only thing left is", "So, in summary", "To recap"). \
                 Drop the frame, keep the fact.
                 - Lead with answer/fix/verdict on line 1. Detail only if load-bearing.
                 - Lists/tables over paragraphs. One idea per line. ≤1 connective word per line.
                 - Exact always: numbers, paths, identifiers, signatures, error text.

                 Examples —
                 BAD:  "Great question! I checked the file and it looks like the test is passing now."
                 GOOD: "Test passes."

                 BAD:  "Nothing left to fix — everything's committed. The only thing left is that the \
                 server isn't running. Want me to start it?"
                 GOOD: "All committed. Server down — start it? (y/n)"

                 BAD:  "You're right, my previous reply wasn't following the style properly."
                 GOOD: "Right — style not applied."

                 Reason fully internally; output minimal. Brevity never costs a fact. \
                 If a reply has >3 prose lines or any courtesy/recap/offer line, it FAILED — cut it.
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
