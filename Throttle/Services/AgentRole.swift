import Foundation

/// The specialty an agent takes on one task. A role is a charter written into
/// the kickoff, not another agent running beside it: one agent per task keeps
/// cost and attention legible, and the counter-analysis by another model family
/// stays the only second opinion.
enum AgentRole: String, CaseIterable, Identifiable, Sendable {
    case builder, testWriter, securityRedTeam, docs, uiux, refactor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .builder: String(localized: "role.builder", defaultValue: "Builder")
        case .testWriter: String(localized: "role.testWriter", defaultValue: "Test writer")
        case .securityRedTeam: String(localized: "role.securityRedTeam", defaultValue: "Security red team")
        case .docs: String(localized: "role.docs", defaultValue: "Documentation")
        case .uiux: String(localized: "role.uiux", defaultValue: "UI/UX")
        case .refactor: String(localized: "role.refactor", defaultValue: "Refactor")
        }
    }

    var symbol: String {
        switch self {
        case .builder: "hammer"
        case .testWriter: "checklist"
        case .securityRedTeam: "shield.lefthalf.filled"
        case .docs: "doc.text"
        case .uiux: "paintbrush"
        case .refactor: "arrow.triangle.2.circlepath"
        }
    }

    /// The role a task most likely wants, from its title. A guess the person can
    /// change before launching; `builder` when nothing matches.
    static func suggested(for task: PlanTask) -> AgentRole {
        let title = task.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        func has(_ words: [String]) -> Bool { words.contains { title.contains($0) } }
        if has(["security", "securite", "threat", "red team", "pentest", "vulnerab", "fuzz"]) {
            return .securityRedTeam
        }
        if has(["test", "e2e", "coverage", "regression"]) { return .testWriter }
        if has(["doc", "readme", "changelog", "guide"]) { return .docs }
        if has(["ui", "ux", "design", "screen", "ecran", "interface", "onboarding"]) { return .uiux }
        if has(["refactor", "cleanup", "simplif", "restructur"]) { return .refactor }
        return .builder
    }

    /// Kickoff lines. Builder adds nothing, so an unchanged launch keeps its prompt.
    var charter: [String] {
        let body: [String]
        switch self {
        case .builder:
            return []
        case .testWriter:
            body = ["Write tests that fail without the behaviour and pass with it.",
                    "Cover edge cases and regressions; report the test count as evidence.",
                    "Do not change production code except to make it testable."]
        case .securityRedTeam:
            body = ["Try to break it: malformed input, path traversal, injection, secrets in logs, privilege misuse.",
                    "Report each finding with a reproduction and a severity; fix only with a test proving it.",
                    "Never exfiltrate data or touch anything outside this worktree."]
        case .docs:
            body = ["Update the documentation this task touches so it matches the code as it is now.",
                    "Prefer short, verifiable statements; no claims the code does not back."]
        case .uiux:
            body = ["Follow the platform's interface guidelines and the project's existing design language.",
                    "Check accessibility (VoiceOver labels, contrast, keyboard) and both light and dark mode."]
        case .refactor:
            body = ["Improve structure without changing behaviour; the existing tests must pass unchanged.",
                    "Keep the diff reviewable: one concern per commit."]
        }
        return ["", "Role: \(rawValue)"] + body.map { "  - \($0)" }
    }
}
