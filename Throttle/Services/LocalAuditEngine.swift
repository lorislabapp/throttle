import Foundation

/// Deterministic, AI-free audit of a Claude Code project's CLAUDE.md +
/// .claude/settings.json + ~/.claude/hooks/. Mirrors the 7 rules
/// shipped in the Throttle MCP server (github.com/lorislabapp/throttle-mcp)
/// so the Mac app and the MCP server emit the same findings — single
/// source of truth for the heuristic ruleset, regardless of whether the
/// user audits via Claude Desktop (MCP), or via the Mac app's Assistant
/// tab.
///
/// Why a local engine when the Assistant already audits via the AI:
///   - **Zero tokens.** Free for the user, instant.
///   - **No drops.** No claude.ai web stream to silently abort, no
///     Apple Intelligence context overflow on big tool-result turns.
///   - **No API key required.** The 7 high-confidence findings work
///     for everybody — Pro/Max subscribers, free trial users,
///     non-AI-key users.
///
/// The AI Assistant remains the right tool for everything heuristics
/// can't catch (custom routing logic, structural CLAUDE.md issues,
/// per-project judgement calls). Local audit is the *floor*, AI is
/// the ceiling.
struct LocalAuditFinding: Sendable, Hashable {
    enum Severity: String, Sendable {
        case high
        case medium
        case low

        var emoji: String {
            switch self {
            case .high:   return "🔴"
            case .medium: return "🟡"
            case .low:    return "⚪️"
            }
        }
    }

    enum Category: String, Sendable {
        case security
        case cost
    }

    let ruleID: String
    let severity: Severity
    let category: Category
    let title: String
    let quote: String
    let message: String
    let fixHint: String
    /// True when the Mac app's Optimizer tab can apply this fix as a
    /// one-click patch. Mirrors the MCP server's `mac_app_can_fix`.
    let macAppCanFix: Bool
}

enum LocalAuditEngine {
    /// Run all 7 rules on the supplied inputs. Any input may be nil
    /// (file not present); the engine just skips rules that need it.
    /// Findings come back ordered by severity (high → medium → low) so
    /// the rendered list reads "fix this first" top-down.
    static func audit(
        claudeMd: (text: String, bytes: Int)?,
        settingsJSON: String?,
        hooksPresent: [String]
    ) -> [LocalAuditFinding] {
        var out: [LocalAuditFinding] = []

        // Parse settings.json once; permissions-based rules share it.
        let parsed = parseJSONObject(settingsJSON)

        // Security — high
        if let f = bashWildcard(parsed: parsed) { out.append(f) }
        out.append(contentsOf: readWriteWildcard(parsed: parsed))
        out.append(contentsOf: curlUnscoped(parsed: parsed))
        // Cost — medium
        if let f = opusDefault(parsed: parsed) { out.append(f) }
        if let md = claudeMd, let f = claudeMdSize(text: md.text, bytes: md.bytes) {
            out.append(f)
        }
        if let f = noSessionStartRouter(hooksPresent: hooksPresent) { out.append(f) }
        // Cost — low
        if let md = claudeMd {
            out.append(contentsOf: claudeMdExternalRef(text: md.text))
        }

        return out.sorted { lhs, rhs in
            severityOrder(lhs.severity) < severityOrder(rhs.severity)
        }
    }

    private static func severityOrder(_ s: LocalAuditFinding.Severity) -> Int {
        switch s {
        case .high:   return 0
        case .medium: return 1
        case .low:    return 2
        }
    }

    private static func parseJSONObject(_ json: String?) -> [String: Any]? {
        guard let json,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func allowList(from parsed: [String: Any]?) -> [String] {
        guard let perms = parsed?["permissions"] as? [String: Any],
              let allow = perms["allow"] as? [String] else { return [] }
        return allow
    }

    // MARK: - Rules

    private static func bashWildcard(parsed: [String: Any]?) -> LocalAuditFinding? {
        let allow = allowList(from: parsed)
        guard allow.contains("Bash(*)") else { return nil }
        return LocalAuditFinding(
            ruleID: "bash_wildcard",
            severity: .high,
            category: .security,
            title: "Unrestricted Bash permission",
            quote: "Bash(*)",
            message: "Bash(*) lets the model run any shell command. A prompt injection in any file the model reads can pivot to data exfiltration or arbitrary writes. Scope to specific binaries instead.",
            fixHint: "Replace `Bash(*)` with the specific commands you actually need, e.g. `Bash(git:*)`, `Bash(swift:*)`, `Bash(xcodebuild:*)`. Use the project's existing call sites to seed the list.",
            macAppCanFix: true
        )
    }

    private static func readWriteWildcard(parsed: [String: Any]?) -> [LocalAuditFinding] {
        let allow = allowList(from: parsed)
        var out: [LocalAuditFinding] = []
        if allow.contains("Read(*)") {
            out.append(LocalAuditFinding(
                ruleID: "read_write_wildcard",
                severity: .high,
                category: .security,
                title: "Unrestricted Read permission",
                quote: "Read(*)",
                message: "Read(*) lets the model read every file in your home directory. A prompt injection chain (e.g. Read your ~/.ssh/) becomes a one-step pivot.",
                fixHint: "Scope Read to the project tree: Read(./**). Repeat the audit on each project's .claude/settings.json so the global allow stays narrow.",
                macAppCanFix: true
            ))
        }
        if allow.contains("Write(*)") {
            out.append(LocalAuditFinding(
                ruleID: "read_write_wildcard",
                severity: .high,
                category: .security,
                title: "Unrestricted Write permission",
                quote: "Write(*)",
                message: "Write(*) lets the model overwrite any file in your home directory. A prompt injection chain (e.g. writing to a path used by another tool) becomes a one-step pivot.",
                fixHint: "Scope Write to the project tree: Write(./**). Repeat the audit on each project's .claude/settings.json so the global allow stays narrow.",
                macAppCanFix: true
            ))
        }
        return out
    }

    private static func curlUnscoped(parsed: [String: Any]?) -> [LocalAuditFinding] {
        let allow = allowList(from: parsed)
        let triggers = ["Bash(curl:*)", "Bash(wget:*)"]
        return triggers.compactMap { trigger -> LocalAuditFinding? in
            guard allow.contains(trigger) else { return nil }
            return LocalAuditFinding(
                ruleID: "curl_unscoped",
                severity: .high,
                category: .security,
                title: "Unrestricted network shell",
                quote: trigger,
                message: "\(trigger) lets the model exfiltrate data to any URL with any payload. A prompt injection in a file read by the assistant can post your tokens, ssh keys, or .env to an attacker-controlled host.",
                fixHint: "Drop the entry. Use WebFetch with a host allowlist when you actually need outbound HTTP — the model has to ask before each new host.",
                macAppCanFix: true
            )
        }
    }

    private static func opusDefault(parsed: [String: Any]?) -> LocalAuditFinding? {
        guard let model = parsed?["model"] as? String,
              model.hasPrefix("claude-opus") else { return nil }
        return LocalAuditFinding(
            ruleID: "opus_default",
            severity: .medium,
            category: .cost,
            title: "Opus set as the default model",
            quote: "\"model\": \"\(model)\"",
            message: "Opus bills roughly 5× Sonnet on Claude Code workloads. For 90% of code edits, Sonnet's accuracy gap is small enough that the model split alone moves your weekly cost the most. Reserve Opus for architecture sessions via `--model claude-opus-4-7` when you need it.",
            fixHint: "Change the field to `\"model\": \"claude-sonnet-4-6\"` or remove it (Claude Code's default is already Sonnet). Spot-spike Opus per session via the CLI flag.",
            macAppCanFix: true
        )
    }

    private static let claudeMdSizeThresholdBytes = 16 * 1024

    private static func claudeMdSize(text: String, bytes: Int) -> LocalAuditFinding? {
        guard bytes > claudeMdSizeThresholdBytes else { return nil }
        return LocalAuditFinding(
            ruleID: "claude_md_size",
            severity: .medium,
            category: .cost,
            title: "CLAUDE.md is large",
            quote: "\(bytes.formatted(.number)) bytes (threshold: \(claudeMdSizeThresholdBytes.formatted(.number)))",
            message: "Every session re-reads CLAUDE.md, so each 1 KB on disk costs ~250 input tokens per session. A file this large dominates the prelude — review for stale conventions, long historical decisions, and content that belongs in subdirectory CLAUDE.mds instead of the root.",
            fixHint: "Move per-area conventions into subdirectory CLAUDE.mds (Claude Code reads them on demand only when you cd into that area). Trim historical context. Inline external .md references that the file points at — or delete the references if the docs are no longer relevant.",
            macAppCanFix: false
        )
    }

    private static func noSessionStartRouter(hooksPresent: [String]) -> LocalAuditFinding? {
        guard !hooksPresent.contains("session-start-router.sh") else { return nil }
        return LocalAuditFinding(
            ruleID: "no_session_start_router",
            severity: .medium,
            category: .cost,
            title: "session-start-router.sh missing",
            quote: "~/.claude/hooks/session-start-router.sh not found",
            message: "Without the session-start router, every Claude Code session prepends your full ~/.claude/CLAUDE.md in input tokens, even when the active project has no use for the global content. The router emits only the slice that matches the current working directory — typically a 60–80% reduction on the always-loaded prelude.",
            fixHint: "Drop a session-start-router.sh into ~/.claude/hooks/ that reads ~/.claude/memory-routing.json and emits only the entries whose path prefix matches the current CWD. Throttle's Mac app can generate it for you.",
            macAppCanFix: true
        )
    }

    private static func claudeMdExternalRef(text: String) -> [LocalAuditFinding] {
        // Match the MCP rule: "Read X.md" anywhere on a line, OR
        // "consult <file>.md before".
        let patterns: [(NSRegularExpression.Options, String)] = [
            ([.anchorsMatchLines], #"^[^\n]*\bRead\s+([A-Za-z0-9_./-]+\.(md|txt|json))\b"#),
            ([.caseInsensitive],    #"\bconsult\s+([A-Za-z0-9_./-]+\.(md|txt|json))\s+before\b"#)
        ]
        var refs: Set<String> = []
        for (opts, pattern) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            re.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard let m = match, m.numberOfRanges >= 2,
                      let r = Range(m.range(at: 1), in: text) else { return }
                refs.insert(String(text[r]))
            }
        }
        return refs.sorted().map { ref in
            LocalAuditFinding(
                ruleID: "claude_md_external_ref",
                severity: .low,
                category: .cost,
                title: "CLAUDE.md forces a per-session file read",
                quote: ref,
                message: "Each session that triggers this directive pays for a tool round-trip plus the file's tokens, even when the reference is irrelevant to the current task. If the file is small and always relevant, inline it. If it's large or rarely needed, drop the directive and trust the model to read on demand.",
                fixHint: "Inline \(ref) into CLAUDE.md if it's <1 KB and always relevant. Otherwise delete the directive — the model will request the file via read_file when it actually needs it.",
                macAppCanFix: false
            )
        }
    }

    /// Render the findings as a Markdown string suitable for posting
    /// into the Assistant chat as a synthetic assistant message. Same
    /// vocabulary the AI uses (numbered list, **bold** titles, `code`
    /// quotes), so the audit looks consistent regardless of which
    /// engine produced it.
    static func renderMarkdown(findings: [LocalAuditFinding]) -> String {
        if findings.isEmpty {
            return "✅ **Local audit: 0 findings.** Your CLAUDE.md, settings.json, and hooks pass the 7 deterministic rules. Run a full AI audit if you want judgement-call findings (CLAUDE.md structure, custom routing logic, etc.)."
        }
        var lines: [String] = []
        let high   = findings.filter { $0.severity == .high }.count
        let medium = findings.filter { $0.severity == .medium }.count
        let low    = findings.filter { $0.severity == .low }.count
        var summary: [String] = []
        if high > 0   { summary.append("\(high) high") }
        if medium > 0 { summary.append("\(medium) medium") }
        if low > 0    { summary.append("\(low) low") }
        lines.append("**Local audit — \(summary.joined(separator: ", "))** _(deterministic, no AI tokens)_")
        lines.append("")
        for (i, f) in findings.enumerated() {
            lines.append("\(i + 1). \(f.severity.emoji) **\(f.title)** — `\(f.quote)`")
            lines.append("   \(f.message)")
            lines.append("   _Fix:_ \(f.fixHint)")
            if i < findings.count - 1 { lines.append("") }
        }
        return lines.joined(separator: "\n")
    }
}
