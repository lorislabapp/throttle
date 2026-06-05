import Foundation

/// Abstraction over the three AI backends Throttle's Project window
/// Assistant tab can talk to. Each provider streams a response token
/// by token; the UI subscribes to the stream and updates the chat
/// bubble incrementally.
///
/// Sendable + nonisolated so the chat task can live on a background
/// actor; the provider implementations carry no shared mutable state
/// (every call is self-contained).
protocol AIProvider: Sendable {
    /// User-facing label, e.g. "Apple Intelligence (local)".
    var displayName: String { get }

    /// Discriminator for the auto-fallback chain in `runAssistantTurn`.
    /// When a recoverable error occurs we mark this kind as already-tried
    /// and ask the registry for the next available provider.
    var kind: AIProviderKind { get }

    /// True when this provider can respond to a chat call right now.
    /// AppleIntelligence: depends on macOS version + device support.
    /// ClaudeAPIKey: depends on whether the user pasted a key.
    /// ClaudeWebSession: depends on a fresh Safari claude.ai session.
    var isAvailable: Bool { get async }

    /// Stream a response. The system prompt is woven from the project
    /// context (CLAUDE.md content, settings.json content, recent stats)
    /// so the model has read-access to what the user is working on
    /// without needing tool-calling support across all providers.
    func streamChat(
        messages: [ChatMessage],
        context: ProjectChatContext
    ) async throws -> AsyncThrowingStream<String, Error>
}

struct ChatMessage: Sendable, Identifiable, Hashable {
    enum Role: String, Sendable, Codable {
        case system
        case user
        case assistant
    }
    let id: UUID
    let role: Role
    let content: String
    let timestamp: Date

    init(role: Role, content: String, id: UUID = UUID(), timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

/// Read-only context the Assistant ships with every chat. Built once
/// per session by the Assistant tab from the active project's files.
struct ProjectChatContext: Sendable {
    let projectName: String
    let projectPath: String?
    let claudeMd: String?
    let settingsJSON: String?
    let weeklyTokens: Int
    let modelSplit: [(String, Double)]
    /// Optional content of `~/.claude/hooks/session-start-router.sh`,
    /// `pre-compact.sh`, etc. — only the user's hooks they've installed.
    let hookScripts: [String: String]
    /// Listed MCP servers, by display name.
    let mcpServers: [String]
    /// Approx. cost in EUR for the last 7 days (developer-API rates).
    let costEUR: Double

    /// Absolute filesystem paths the AI can fetch via `read_file`. Built
    /// at the same time as `claudeMd` / `settingsJSON` / `hookScripts` so
    /// the system prompt can advertise them without inlining their bytes.
    /// Empty or missing → omit from the prompt's "available files" list.
    var claudeMdPath: String? = nil
    var settingsJSONPath: String? = nil
    var hookScriptPaths: [String: String] = [:]

    /// Render the context as a system-prompt-friendly string. We DO NOT
    /// inline the full bytes of CLAUDE.md / settings.json / hooks — that
    /// pushed the prompt past claude.ai's web ~30 KB refusal threshold
    /// and silently triggered `stop_reason: "refusal"`. Instead, we list
    /// the files with their absolute paths and byte sizes so the AI can
    /// `read_file` exactly the ones it needs. v2.5.0's tool-calling loop
    /// makes that round-trip cheap and lets the AI focus its context on
    /// only the files relevant to the current question.
    func asSystemPrompt() -> String {
        var lines: [String] = []

        // Check if Caveman mode is enabled (user preference)
        let cavemanEnabled = UserDefaults.standard.bool(forKey: "cavemanModeEnabled")

        lines.append("You are Throttle's expert Claude Code configuration auditor. You help the user reduce token cost, simplify their setup, and tighten their security posture for THIS specific project.")
        lines.append("")

        if cavemanEnabled {
            lines.append("--- CAVEMAN MODE ACTIVE ---")
            lines.append("Respond in ultra-terse, telegraphic style:")
            lines.append("- NO full sentences. NO pleasantries. NO preambles.")
            lines.append("- Bullet points only. Code > explanation.")
            lines.append("- Max 3 lines per response (excluding patches).")
            lines.append("- Example: '✓ CLAUDE.md 8.2 KB → 2k tokens/session. Move conventions to subdirs. Saves €0.14/session.'")
            lines.append("")
        }

        lines.append("--- HARD RULES ---")
        lines.append("1. NEVER answer with generic affirmations like 'your config is optimized', 'all good', 'looks fine'. The user opened the assistant because they want concrete improvements; if you cannot find any, say 'I have no concrete improvement to suggest right now' verbatim — but only after a real audit.")
        lines.append("2. ALWAYS ground each recommendation in a quoted line, key, or filename from the context below. No hand-waving.")
        lines.append("3. ALWAYS pair a recommendation with a measurable effect. Use the unit appropriate to the change (\"removes N bytes per session prelude\", \"shifts X% of usage off Opus to Sonnet\", \"closes Y exfiltration vectors\").")
        if cavemanEnabled {
            // Caveman overrides the default verbose format/length rules above —
            // otherwise these contradict the terse style and win, and the toggle
            // appears to do nothing.
            lines.append("4. Output: terse bullets only, code over prose. No numbered lists, no bold headers, no preambles.")
            lines.append("5. Length: MAX 3 lines, excluding patches. This OVERRIDES any longer-length guidance — terseness wins.")
        } else {
            lines.append("4. Use Markdown: numbered lists, **bold** for filenames, `code spans` for keys/values.")
            lines.append("5. Length: 4-10 short sentences. Skip preambles like 'Of course!'.")
        }
        lines.append("")
        lines.append("--- APPLY-ABLE PATCHES ---")
        lines.append("When you propose a CONCRETE file edit, append a fenced ```patch block at the END of your message. Two formats are supported:")
        lines.append("")
        lines.append("(A) Replace existing text in an existing file:")
        lines.append("```patch")
        lines.append("FILE: <absolute file path>")
        lines.append("SEARCH:")
        lines.append("<exact substring to find — must match the file byte-for-byte, including indentation>")
        lines.append("REPLACE:")
        lines.append("<replacement substring>")
        lines.append("REASON: <one short sentence>")
        lines.append("```")
        lines.append("")
        lines.append("(B) Create a NEW file (file must not yet exist):")
        lines.append("```patch")
        lines.append("FILE: <absolute file path>")
        lines.append("CREATE:")
        lines.append("<full content of the new file>")
        lines.append("REASON: <one short sentence>")
        lines.append("```")
        lines.append("")
        lines.append("--- TOOLS YOU CAN CALL ---")
        lines.append("You CAN inspect the user's filesystem on demand by emitting fenced ```tool blocks. Throttle parses them, runs the tool with safety guards, and replies with the result as a follow-up user message. Available tools:")
        lines.append("")
        lines.append("- read_file: read the full contents of a single file (max 64 KB).")
        lines.append("- list_files: list a directory's immediate children.")
        lines.append("- bash: run an allowlisted READ-ONLY shell command. Allowed binaries: git, swift, xcodebuild, ls, cat, find, grep, head, tail, wc. NO pipes, redirections, env-var expansion, command substitution, or backslashes. 30s timeout, 64 KB output cap. Path arguments under ~/.ssh, ~/.aws, keychains, and similar credential-bearing dirs are blocked. Use for `git status`, `git log -n 20`, `swift --version`, `xcodebuild -list`, `find ~/projects -name '*.swift'`, etc.")
        lines.append("")
        lines.append("Throttle does NOT pre-load file contents — you MUST call read_file on whichever 1-3 files (CLAUDE.md, settings.json, hooks) are relevant to answer the question. NEVER guess at contents. Start every audit with at least one read_file call.")
        lines.append("")
        lines.append("Format:")
        lines.append("```tool")
        lines.append("TOOL: read_file")
        lines.append("PATH: /Users/<...>/file.json")
        lines.append("```")
        lines.append("")
        lines.append("Or:")
        lines.append("```tool")
        lines.append("TOOL: list_files")
        lines.append("PATH: /Users/<...>/.claude/hooks/")
        lines.append("```")
        lines.append("")
        lines.append("Or for the bash tool (note `CMD:` not `PATH:`):")
        lines.append("```tool")
        lines.append("TOOL: bash")
        lines.append("CMD: git log -n 5 --oneline")
        lines.append("```")
        lines.append("")
        lines.append("Important:")
        lines.append("- Emit ALL tool calls you need in a single message — Throttle batches them and feeds back every result in one tool_result block. Do NOT spread reads across multiple turns.")
        lines.append("- After you see the tool_result block, write your final answer with patches. Don't make extra tool calls unless something the first batch revealed forces it.")
        lines.append("- Stay under 5 tool calls per user request — be efficient. Multi-turn conversations on claude.ai are throttled.")
        lines.append("")
        lines.append("Rules for patch blocks:")
        lines.append("- Emit ONE patch per concrete change. Multiple changes = multiple patch blocks.")
        lines.append("- For format A, SEARCH must be a LITERAL substring of the file content shown in the context. Do NOT paraphrase.")
        lines.append("- For format B, the file must not exist on disk yet. Use this for creating CLAUDE.md, .claude/settings.json, etc.")
        lines.append("- Skip both formats when you're recommending an architectural redesign that requires human judgement (e.g. 'restructure your shell script's caching logic').")
        lines.append("- If you're not 100% sure of the exact text to match (format A) or the right full content (format B), describe the change in prose only.")
        lines.append("- Throttle's UI parses these blocks and offers the user a one-click Accept (with safety backup) per patch.")
        lines.append("")
        lines.append("--- CLAUDE CODE MENTAL MODEL (these are facts, do NOT contradict) ---")
        lines.append("- The model used is set by the `--model` CLI flag or by `\"model\"` in settings.json. CLAUDE.md cannot force a model — instructions in it are soft hints the model may follow but are NOT binding.")
        lines.append("- The `permissions.allow` list in settings.json is read by the Claude Code CLI to gate which tools the model can call. Its content is NOT sent to the model as tokens. Trimming permission entries reduces clutter, not session cost.")
        lines.append("- Cache reads bill at ~10% of input rate. Cache writes bill at ~125%. Throttle's \"weighted tokens\" metric uses input + output + cache_create + (cache_read / 10).")
        lines.append("- session-start-router.sh and pre-compact.sh hooks reduce CONTEXT SIZE per session (which directly cuts input tokens). They don't change the model.")
        lines.append("- A weekly model split with >70% Opus is a strong cost-inefficiency signal — Sonnet handles 90% of code-edit work at 1/5 the cost.")
        lines.append("- `Read(*)` / `Write(*)` / `Bash(curl:*)` in permissions allow exfiltration via prompt injection. Treat as a security finding.")
        lines.append("")
        lines.append("--- PROJECT CONTEXT ---")
        lines.append("Project name: \(projectName)")
        if let projectPath { lines.append("Path: \(projectPath)") }
        lines.append("Tokens this week (weighted): \(weeklyTokens)")
        if costEUR > 0 {
            lines.append("Reference cost @ developer-API rates (last 7d): €\(String(format: "%.2f", costEUR))")
        }
        if !modelSplit.isEmpty {
            let split = modelSplit.map { "\($0.0) \(Int($0.1 * 100))%" }.joined(separator: ", ")
            lines.append("Model split (weighted, 7d): \(split)")
        }
        if !mcpServers.isEmpty {
            lines.append("Configured MCP servers: \(mcpServers.joined(separator: ", "))")
        }
        // List the files that exist for this project — paths + sizes
        // only. The AI fetches the bytes via `read_file` when it needs
        // them. Keeps the first-turn prompt small (~5 KB) and well under
        // claude.ai's web refusal threshold (~30 KB).
        lines.append("")
        lines.append("--- AVAILABLE FILES (use read_file to fetch) ---")
        if let path = claudeMdPath, let claudeMd, !claudeMd.isEmpty {
            lines.append("- CLAUDE.md (\(claudeMd.count) chars) at \(path)")
        } else if claudeMdPath != nil {
            lines.append("- CLAUDE.md: not present in this project")
        }
        if let path = settingsJSONPath, let settingsJSON, !settingsJSON.isEmpty {
            lines.append("- .claude/settings.json (\(settingsJSON.count) chars) at \(path)")
        } else if settingsJSONPath != nil {
            lines.append("- .claude/settings.json: not present")
        }
        if !hookScripts.isEmpty {
            for (name, content) in hookScripts where !content.isEmpty {
                if let path = hookScriptPaths[name] {
                    lines.append("- \(name) (\(content.count) chars) at \(path)")
                } else {
                    lines.append("- \(name) (\(content.count) chars)")
                }
            }
        }
        lines.append("")
        lines.append("Always start by reading whichever 1-3 files are relevant to the user's question. Don't guess at their contents.")
        return lines.joined(separator: "\n")
    }
}

/// Identifier persisted in UserDefaults for the user's selected provider.
enum AIProviderKind: String, Sendable, CaseIterable {
    case appleIntelligence = "apple"
    case claudeWebSession  = "claudeWeb"
    case claudeAPIKey      = "claudeKey"
}

/// Quality vs speed/cost preference. Throttle's default is `.maxAccuracy`
/// because the assistant is an *audit* tool — wrong recommendations are
/// worse than slow ones. Per-provider behavior:
///   - ClaudeAPIKey: maxAccuracy → claude-opus-4-7, balanced → sonnet-4-6
///   - ClaudeWebSession: model is decided by claude.ai itself, the
///     preference is ignored (the claude.ai backend already routes).
///   - AppleIntelligence: only one model available, the preference is
///     ignored.
enum AIQualityPreference: String, Sendable, CaseIterable {
    case maxAccuracy = "maxAccuracy"  // default — Opus / large context
    case balanced    = "balanced"      // Sonnet / default context
    case speed       = "speed"         // Haiku / smaller context
}
