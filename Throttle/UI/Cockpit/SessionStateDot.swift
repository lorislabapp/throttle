import SwiftUI

/// The session's state dot, as its own View.
///
/// It was a `private func … -> some View` on the root, which means the read of
/// `tab.state` happened inside `MultiCockpitRoot.body`'s observation scope. And
/// `state` reads `lastActivityAt`, which the PTY writes on every chunk — so one
/// streaming session invalidated the entire cockpit: top bar, banners, rail,
/// split view, inspector. This is the same defect that once made the menu bar
/// eat 42 GB, relocated.
///
/// A real View type scopes the observation to the dot. Creating it from the
/// parent reads nothing; SwiftUI evaluates this body in its own scope.
/// Keep the tooltip here too: computing `.help(tab.state...)` at the call site
/// would subscribe the parent to the same activity changes again.
struct SessionStateDot: View {
    let tab: CockpitTab

    var body: some View {
        shape.help(helpText)
    }

    @ViewBuilder
    private var shape: some View {
        switch tab.state {
        case .working:
            Circle().fill(Color.green).frame(width: 6, height: 6)
        case .rateLimited:
            Circle().fill(Color.red).frame(width: 6, height: 6)
        case .paused:
            Image(systemName: "pause.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(.purple)
                .frame(width: 7, height: 7)
        case .waiting:
            Circle().strokeBorder(Color.orange, lineWidth: 1.5).frame(width: 7, height: 7)
        case .idle:
            Circle().fill(Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
        case .dormant, .hibernated:
            Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1).frame(width: 6, height: 6)
        }
    }

    private var helpText: String {
        switch tab.state {
        case .working:    return "Working"
        case .paused:     return tab.pauseReason?.resumesOnFocus == true
            ? "\(tab.pauseReason?.title ?? "Paused") — focus this tab to resume instantly, 0 tokens"
            : "\(tab.pauseReason?.title ?? "Paused") — click ▶ to resume"
        case .rateLimited:
            let when = tab.rateLimitedUntil.map {
                " — frees up in \(MultiCockpitModel.countdown(Int64($0.timeIntervalSinceNow)))"
            } ?? ""
            return "Rate-limited\(when)"
        case .waiting:    return "Claude answered — waiting for you"
        case .idle:       return "Idle (at prompt)"
        case .dormant:    return "Not started"
        case .hibernated: return "Hibernated"
        }
    }
}
