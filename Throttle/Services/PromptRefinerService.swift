import Foundation

/// What the user is refining. The target decides both the system prompt and
/// where an accepted proposal lands.
enum RefinerMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case session, mission, loop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .session: return "Session"
        case .mission: return "Mission"
        case .loop:    return "/loop"
        }
    }

    var help: String {
        switch self {
        case .session: return "Refine the next instruction for the running session"
        case .mission: return "Refine a long autonomous mission objective"
        case .loop:    return "Refine a /loop objective — it must be able to self-terminate"
        }
    }
}

/// A one-word re-refinement asked for from the result screen.
enum RefinerNudge: String, CaseIterable, Identifiable, Sendable {
    case shorter, precise, constraints

    var id: String { rawValue }

    var label: String {
        switch self {
        case .shorter:     return "shorter"
        case .precise:     return "precise"
        case .constraints: return "+ constraints"
        }
    }

    var instruction: String {
        switch self {
        case .shorter:     return "Cut the length hard. Keep every constraint and every file path."
        case .precise:     return "Tighten the scope: name the exact files, symbols and commands."
        case .constraints: return "Add explicit guardrails: what must not change, and what evidence proves it worked."
        }
    }
}

/// Proposes an improved prompt. It never writes a file, never touches a PTY and
/// never sends anything — the caller applies, the user fires.
enum PromptRefinerService {

    struct Refinement: Sendable, Equatable {
        let proposed: String
        let why: [String]
        let changed: Bool
        var provider: String = ""
    }

    struct PromptMetrics: Sendable, Equatable {
        let lines: Int
        let bytes: Int
        let approxTokens: Int
    }

    enum RefinerError: LocalizedError, Equatable {
        case noProvider
        case empty
        case controlSequence
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .noProvider:
                return "No AI provider available — sign in to claude.ai or add an API key in the Assistant tab."
            case .empty:
                return "The model returned nothing usable."
            case .controlSequence:
                return "The text contains a control sequence and was not applied."
            case .tooLarge:
                return "Prompts are limited to 1 MiB."
            }
        }
    }

    /// Same ceiling as a reviewed terminal paste — a live PTY is the consumer in
    /// both cases.
    static let maximumBytes = 1024 * 1024

    // MARK: - Payload safety

    /// Text ready to paste into a terminal. Trailing newlines are stripped: a
    /// newline reaching the TUI IS the Enter key, and the whole promise of this
    /// feature is that only the user presses it.
    static func insertionPayload(_ text: String) -> String {
        var out = text
        while out.hasSuffix("\n") || out.hasSuffix("\r") { out.removeLast() }
        return out
    }

    /// Hard invariants, kept from `ReviewedPasteService`: no NUL, no ESC, 1 MiB.
    /// The confirmation ALERT is deliberately not reused — the result screen
    /// already shows the whole text plus its line/byte/token cost, which is more
    /// review than a truncated preview.
    static func validate(_ text: String) throws {
        guard text.utf8.count <= maximumBytes else { throw RefinerError.tooLarge }
        guard !text.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 0x1b }) else {
            throw RefinerError.controlSequence
        }
    }

    /// The cost evidence shown before applying. `bytes / 4` is the same
    /// approximation the reviewed-paste sheet already shows, so two surfaces
    /// never quote the user two different numbers for one payload.
    static func metrics(_ text: String) -> PromptMetrics {
        let bytes = text.utf8.count
        let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
        return PromptMetrics(lines: lines, bytes: bytes, approxTokens: max(1, bytes / 4))
    }
}
