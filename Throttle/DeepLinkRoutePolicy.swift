import Foundation

/// What a `throttle://` URL asks for, and whether Throttle may do it without
/// asking. Any app, web page or message can open a `throttle://` URL, so a URL
/// alone must never change state: navigation runs directly, everything that
/// pauses sessions, mutes Throttle or activates a licence waits for the user
/// to approve it in an alert. Pure so the policy is testable without AppKit.
enum DeepLinkRoute: Equatable, Sendable {
    /// `throttle://activate?key=THROTTLE-…` from the purchase email.
    case activate(key: String)
    case cockpit
    /// `throttle://research-vault[/library]`; `/library` only raises the
    /// folder picker, which still needs the user to choose a folder.
    case researchVault(connectLibrary: Bool)
    /// `pause`, `resume`, `quiet`, `unquiet`.
    case command(ThrottleAction)
    /// Wrong scheme, unknown host or malformed parameters.
    case ignored(reason: String)

    static func parse(_ url: URL) -> DeepLinkRoute {
        guard url.scheme?.lowercased() == "throttle" else {
            return .ignored(reason: "unknown scheme")
        }
        switch url.host?.lowercased() {
        case "activate":
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let key = comps?.queryItems?.first(where: { $0.name == "key" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard let key, key.hasPrefix("THROTTLE-") else {
                return .ignored(reason: "activate URL missing or malformed key")
            }
            return .activate(key: key)
        case "cockpit":
            return .cockpit
        case "research-vault":
            return .researchVault(connectLibrary: url.path.lowercased() == "/library")
        case "pause":   return .command(.pauseAll)
        case "resume":  return .command(.resumeAll)
        case "quiet":   return .command(.quietOn)
        case "unquiet": return .command(.quietOff)
        default:
            return .ignored(reason: "unknown host")
        }
    }

    /// True when the route changes state and must be approved in-app first.
    var requiresConfirmation: Bool {
        switch self {
        case .activate, .command: return true
        case .cockpit, .researchVault, .ignored: return false
        }
    }

    /// The question the confirmation alert asks. Nil for routes that run directly.
    var confirmationPrompt: String? {
        switch self {
        case .activate(let key):
            return "A link wants to activate Throttle Pro with the licence key \(Self.maskedKey(key)). Activate it?"
        case .command(.pauseAll):
            return "A link wants to pause every running session. Pause them?"
        case .command(.resumeAll):
            return "A link wants to resume every paused session. Resume them?"
        case .command(.quietOn):
            return "A link wants to turn on quiet mode. Turn it on?"
        case .command(.quietOff):
            return "A link wants to turn off quiet mode. Turn it off?"
        case .cockpit, .researchVault, .ignored:
            return nil
        }
    }

    /// Keeps the prefix and the last group so the user can recognise the key
    /// from their purchase email without the alert showing all of it.
    static func maskedKey(_ key: String) -> String {
        let groups = key.split(separator: "-")
        guard groups.count >= 3, let last = groups.last else { return "THROTTLE-…" }
        return "\(groups[0])-…-\(last)"
    }
}
