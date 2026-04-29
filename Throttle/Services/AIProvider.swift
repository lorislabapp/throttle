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

    /// Render the context as a system-prompt-friendly string. Truncates
    /// CLAUDE.md and settings.json at 4 KB each so we don't ship more
    /// than ~10 KB of pre-prompt to providers with smaller context windows.
    func asSystemPrompt() -> String {
        var lines: [String] = []
        lines.append("You are Throttle's project assistant. The user is working on a Claude Code project.")
        lines.append("Be concise. When suggesting changes to files, describe them in plain English — the user will apply them via Throttle's Optimizer tab.")
        lines.append("")
        lines.append("Project: \(projectName)")
        if let projectPath { lines.append("Path: \(projectPath)") }
        lines.append("Tokens this week: \(weeklyTokens)")
        if !modelSplit.isEmpty {
            let split = modelSplit.map { "\($0.0) \(Int($0.1 * 100))%" }.joined(separator: ", ")
            lines.append("Model split: \(split)")
        }
        if let claudeMd, !claudeMd.isEmpty {
            lines.append("")
            lines.append("CLAUDE.md (\(claudeMd.count) chars):")
            lines.append(truncate(claudeMd, max: 4096))
        }
        if let settingsJSON, !settingsJSON.isEmpty {
            lines.append("")
            lines.append(".claude/settings.json (\(settingsJSON.count) chars):")
            lines.append(truncate(settingsJSON, max: 4096))
        }
        return lines.joined(separator: "\n")
    }

    private func truncate(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max)) + "\n[…truncated]"
    }
}

/// Identifier persisted in UserDefaults for the user's selected provider.
enum AIProviderKind: String, Sendable, CaseIterable {
    case appleIntelligence = "apple"
    case claudeWebSession  = "claudeWeb"
    case claudeAPIKey      = "claudeKey"
}
