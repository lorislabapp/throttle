import Foundation

/// What Insert does with an accepted proposal.
enum RefinerOutput: String, CaseIterable, Identifiable, Sendable {
    case insert, copy, send

    var id: String { rawValue }

    var label: String {
        switch self {
        case .insert: return "Insert without sending"
        case .copy:   return "Copy to clipboard"
        case .send:   return "Send immediately"
        }
    }
}

/// When the "why it changed" bullets are shown.
enum RefinerRationale: String, CaseIterable, Identifiable, Sendable {
    case always, collapsed, missionOnly, never

    var id: String { rawValue }

    var label: String {
        switch self {
        case .always:      return "Always show"
        case .collapsed:   return "Collapsed"
        case .missionOnly: return "Only for missions and loops"
        case .never:       return "Never"
        }
    }

    /// Session is the fast path; mission and loop are the paths where the user
    /// is about to commit to a long run and should see the reasoning first.
    func isVisible(for mode: RefinerMode) -> Bool {
        switch self {
        case .always:      return true
        case .never:       return false
        case .collapsed:   return false
        case .missionOnly: return mode != .session
        }
    }

    /// Whether a disclosure control is offered at all.
    var isExpandable: Bool { self != .never }
}

/// Persisted refiner preferences. Model choice and quality deliberately reuse
/// `AIProviderRegistry` rather than duplicating a second set of controls.
enum RefinerSettings {
    static let outputKey = "throttleRefinerOutput"
    static let forceLocalKey = "throttleRefinerForceLocal"
    static let rationaleKey = "throttleRefinerRationale"

    /// Injectable ON PURPOSE. The macOS test bundle is app-hosted
    /// (`TEST_HOST` is Throttle.app), so `.standard` inside a test is the user's
    /// LIVE preference domain — a test that clears these keys would silently
    /// reset the settings of whoever ran it. Tests point this at their own suite.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    static var output: RefinerOutput {
        get { RefinerOutput(rawValue: defaults.string(forKey: outputKey) ?? "") ?? .insert }
        set { defaults.set(newValue.rawValue, forKey: outputKey) }
    }

    /// Defaults ON: paying frontier tokens to save frontier tokens is the trap
    /// this product refuses elsewhere.
    static var forceLocal: Bool {
        get { defaults.object(forKey: forceLocalKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: forceLocalKey) }
    }

    static var rationale: RefinerRationale {
        get { RefinerRationale(rawValue: defaults.string(forKey: rationaleKey) ?? "") ?? .missionOnly }
        set { defaults.set(newValue.rawValue, forKey: rationaleKey) }
    }
}

/// Refiner state. It lives OUTSIDE the view tree on purpose: the sidebar renders
/// one segment at a time (the Audit segment owns a polling task that must not
/// run off-screen), so a pane can be torn down at any moment. Holding the draft
/// here means switching segments never loses typed text.
@MainActor
@Observable
final class PromptRefinerModel {
    static let shared = PromptRefinerModel()

    static let historyLimit = 20

    enum Screen: Equatable {
        case home
        case compose
        case loading
        case error(String)
        case result
        /// Direction 1c keeps the result on screen after Insert, with a
        /// "you press Return" confirmation, instead of dropping the user home.
        case applied
    }

    struct HistoryEntry: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let mode: RefinerMode
        let draft: String
        let proposed: String
        let createdAt: Date
    }

    var screen: Screen = .home
    var mode: RefinerMode = .session
    var draft = ""
    var proposal: PromptRefinerService.Refinement?
    var history: [HistoryEntry] = []

    /// True only while the result screen's compare control is held down.
    var peeking = false

    /// A refined mission objective waiting to seed the next handoff sheet.
    var pendingMissionObjective: String?

    func beginCompose() {
        screen = .compose
    }

    func accept(_ refinement: PromptRefinerService.Refinement) {
        proposal = refinement
        screen = .result
        let title = draft
            .split(separator: "\n", omittingEmptySubsequences: true).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? "Untitled draft"
        history.insert(HistoryEntry(title: title, mode: mode, draft: draft,
                                    proposed: refinement.proposed, createdAt: Date()),
                       at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
    }

    func fail(_ message: String) {
        screen = .error(message)
    }

    func reopen(_ entry: HistoryEntry) {
        mode = entry.mode
        draft = entry.draft
        proposal = nil
        screen = .compose
    }

    func reset() {
        screen = .home
        draft = ""
        proposal = nil
        peeking = false
        history = []
        pendingMissionObjective = nil
    }
}
