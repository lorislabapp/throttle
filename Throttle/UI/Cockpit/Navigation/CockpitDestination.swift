import Foundation

/// The four places the Cockpit can show, plus the project pages under Projects.
/// Replaces six peer view modes that gave no starting point.
enum CockpitDestination: Hashable, Sendable {
    /// What waits on the person, across every session and project.
    case today
    /// One project: its overview and its plan. Keyed by the project folder.
    case project(path: String)
    /// Every repository and how they share code and research.
    case portfolio
    /// The live sessions and their terminals.
    case sessions
    /// Quota, spend and the four kinds of cost.
    case usage

    var title: String {
        switch self {
        case .today: String(localized: "cockpit.nav.today", defaultValue: "Today")
        case .project(let path): URL(fileURLWithPath: path).lastPathComponent
        case .portfolio: String(localized: "cockpit.nav.portfolio", defaultValue: "Portfolio map")
        case .sessions: String(localized: "cockpit.nav.sessions", defaultValue: "Sessions")
        case .usage: String(localized: "cockpit.nav.usage", defaultValue: "Usage and costs")
        }
    }
}
