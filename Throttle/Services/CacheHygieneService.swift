import Foundation

/// Audits the local Claude Code config for prompt-cache hygiene. The biggest
/// silent cost is busting Anthropic's prompt cache: cached input tokens bill at
/// ~10% of the normal rate, but injecting *changing* content into the cached
/// prefix (e.g. a SessionStart hook that emits a different prelude each session)
/// invalidates it — you pay full price every time. Throttle detects the
/// cache-prefix injectors and flags the dynamic ones. Detect + explain only;
/// it never edits the user's hooks.
struct CacheRisk: Sendable, Identifiable {
    enum Severity: Sendable { case high, info }
    let id: String
    let title: String
    let detail: String
    let severity: Severity
}

struct CacheHygieneReport: Sendable {
    let risks: [CacheRisk]
    var highCount: Int { risks.filter { $0.severity == .high }.count }
    static let empty = CacheHygieneReport(risks: [])
}

enum CacheHygieneService {
    /// Events whose hook stdout is injected into the prompt / cached prefix.
    private static let injectionEvents = ["SessionStart", "UserPromptSubmit"]

    /// High-confidence markers that a hook emits *genuinely varying* content
    /// (clock / randomness / host-identity / live network) → busts the cache.
    /// Deliberately NOT broad file-read or substitution tokens (`cat `, `$(`,
    /// `memory`, bare `date`): reading a STABLE file or routing by cwd is cache-
    /// FRIENDLY, and bare "date" matched "update"/"candidate". Flagging a
    /// deterministic hook as a cost is a claim we can't stand behind.
    private static let dynamicMarkers = [
        "$(date", "`date", "date +", "date -u", "+%s",              // wall-clock
        "$random", "${random", "uuidgen", "$(uuidgen",             // randomness
        "timestamp", "epoch", "nanosecond",
        "$(hostname", "`hostname", "ifconfig", "ipconfig",         // host/net identity
        "curl ", "wget ",                                          // live network fetch
    ]

    static func scan() -> CacheHygieneReport {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settings = home.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settings),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = obj["hooks"] as? [String: Any] else {
            return .empty
        }

        var risks: [CacheRisk] = []
        for event in injectionEvents {
            guard let entries = hooks[event] as? [[String: Any]] else { continue }
            for entry in entries {
                guard let cmds = entry["hooks"] as? [[String: Any]] else { continue }
                for cmd in cmds {
                    guard let command = cmd["command"] as? String else { continue }
                    let name = (command as NSString).lastPathComponent
                    let dynamic = looksDynamic(command: command, home: home)
                    if dynamic {
                        risks.append(CacheRisk(
                            id: "\(event):\(command)",
                            title: "\(event) hook · \(name)",
                            detail: "Emits content into the cached prompt prefix that appears to vary per session. Changing prefix → the 90%-cheaper cache is invalidated and you pay full input price every time. Keep the injected text byte-stable, or move the varying part out of the cached prefix.",
                            severity: .high
                        ))
                    } else {
                        risks.append(CacheRisk(
                            id: "\(event):\(command)",
                            title: "\(event) hook · \(name)",
                            detail: "Injects into the cached prefix but looks static — fine for the cache as long as its output never changes.",
                            severity: .info
                        ))
                    }
                }
            }
        }
        // CLAUDE.md content: it's loaded into every session's cached prefix, so
        // volatile literals (a date, an "as of" marker, a UUID) bust the cache
        // the moment they change or the file is edited.
        let globalMd = home.appendingPathComponent(".claude/CLAUDE.md")
        if let text = try? String(contentsOf: globalMd, encoding: .utf8) {
            let hits = volatileHits(in: text)
            if !hits.isEmpty {
                risks.append(CacheRisk(
                    id: "claudemd-volatile",
                    title: "CLAUDE.md · volatile content",
                    detail: "Contains \(hits.joined(separator: ", ")) in the cached prompt prefix. CLAUDE.md loads into every session's cached prefix — when that literal changes (or you edit the file) the 90%-cheaper cache is invalidated. Move the varying detail into an on-demand skill (.claude/skills) so the prefix stays byte-stable.",
                    severity: .high))
            }
        }

        return CacheHygieneReport(risks: risks)
    }

    /// Only GENUINELY volatile literals — high confidence, low false-positive.
    /// (Static dates like "since 2026-04-17" are facts, not cache-busters, so we
    /// deliberately do NOT flag bare dates — flagging a fact as a cost would be a
    /// claim we can't stand behind.)
    private static func volatileHits(in text: String) -> [String] {
        var hits: [String] = []
        if text.range(of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", options: .regularExpression) != nil { hits.append("a UUID") }
        return Array(Set(hits))
    }

    /// Read the hook script (best-effort) and check for dynamic-output markers.
    private static func looksDynamic(command: String, home: URL) -> Bool {
        let path = command
            .replacingOccurrences(of: "$HOME", with: home.path)
            .replacingOccurrences(of: "~", with: home.path)
            .components(separatedBy: " ").first ?? command
        guard let script = try? String(contentsOfFile: path, encoding: .utf8) else {
            // Can't read it → don't cry wolf. Flagging an unverifiable hook as a
            // definite cache-buster is a claim we can't stand behind (golden rule);
            // it surfaces as a benign .info instead.
            return false
        }
        // A volatile marker only busts the cache if it reaches STDOUT (the injected
        // prefix). Markers on comment lines, variable assignments, or file-redirected
        // telemetry (e.g. `TS=$(date +%s)` then `>> savings.jsonl`) never enter the
        // prompt — flagging those is the false positive that lit up clean hooks.
        for raw in script.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            let lower = line.lowercased()
            guard dynamicMarkers.contains(where: { lower.contains($0) }) else { continue }
            let redirectsToFile = lower.contains(">>") || lower.contains("> \"")
                || lower.contains("> $") || lower.contains("/dev/null")
                || lower.contains(".jsonl") || lower.contains(".log") || lower.contains("tee ")
            let isAssignment = line.range(of: "^[a-z_][a-z0-9_]*=", options: [.regularExpression, .caseInsensitive]) != nil
            if redirectsToFile || isAssignment { continue }   // telemetry/var, not stdout
            return true                                       // volatile content on a stdout-bound line
        }
        return false
    }
}
