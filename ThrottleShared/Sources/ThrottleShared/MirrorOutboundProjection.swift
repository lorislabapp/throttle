import Foundation
import ThrottleMirrorContract

public extension ThrottleMirrorSnapshot {
    /// The payload as it may leave this Mac. Every free-form string a person
    /// can influence — a device name, a project folder, a host, a model label —
    /// is passed through `OutboundPolicy`, so a credential that ended up in one
    /// of them is masked by kind at the boundary rather than trusted never to
    /// have got there. Numbers, dates and states are left alone: they cannot
    /// carry a secret and rewriting them would only make the mirror wrong.
    func scrubbedForPublication() -> ThrottleMirrorSnapshot {
        ThrottleMirrorSnapshot(
            publishedAt: publishedAt,
            deviceName: OutboundPolicy.scrub(deviceName),
            fiveHour: fiveHour, sevenDay: sevenDay, sevenDaySonnet: sevenDaySonnet,
            weeklyTokens: weeklyTokens, weeklyCostEUR: weeklyCostEUR,
            savedTokensThisWeek: savedTokensThisWeek,
            sessionCount: sessionCount,
            tabs: tabs.map { $0.scrubbedForPublication() },
            peerPairingSecret: peerPairingSecret,
            peerFallbackHost: peerFallbackHost.map(OutboundPolicy.scrub),
            edgeHost: edgeHost.map(OutboundPolicy.scrub),
            edgePort: edgePort, edgeToken: edgeToken,
            schemaVersion: schemaVersion
        )
    }
}

public extension TabMirror {
    func scrubbedForPublication() -> Self {
        Self(
            id: id,
            projectName: OutboundPolicy.scrub(projectName),
            state: state,
            model: model.map(OutboundPolicy.scrub),
            eur: eur,
            tokens: tokens,
            isLive: isLive,
            needsInput: needsInput,
            rateLimitedUntil: rateLimitedUntil
        )
    }
}
