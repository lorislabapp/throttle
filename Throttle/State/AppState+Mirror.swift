import Foundation
import ThrottleShared

extension CockpitTab.SessionState {
    /// Canonical label shipped to the iOS mirror (matches `SessionStateMirror`).
    var mirrorLabel: String {
        switch self {
        case .dormant:     return SessionStateMirror.dormant.rawValue
        case .hibernated:  return SessionStateMirror.hibernated.rawValue
        case .rateLimited: return SessionStateMirror.rateLimited.rawValue
        case .paused:      return SessionStateMirror.paused.rawValue
        case .working:     return SessionStateMirror.working.rawValue
        case .waiting:     return SessionStateMirror.waiting.rawValue
        case .idle:        return SessionStateMirror.idle.rawValue
        }
    }
}

extension AppState {
    /// Assemble the cross-device mirror payload from current state: the exact
    /// windows (utilization + reset), the already-computed weekly aggregates
    /// (passed in from `refresh()` so we don't recompute), and a flat, read-only
    /// projection of the live cockpit tabs (capped at 16 to stay well under the
    /// CloudKit record size limit).
    @MainActor
    func mirrorSnapshot(weeklyTokens: Int,
                        weeklyCostEUR: Double,
                        savedTokensThisWeek: Int) -> ThrottleMirrorSnapshot {
        func win(_ w: ExactSnapshot.Window?) -> WindowMirror {
            WindowMirror(utilization: w?.utilization ?? 0, resetsAt: w?.resetsAt)
        }
        let ex = exactSnapshot
        let sessions = MultiCockpitModel.shared.sessions
        let tabs = sessions.prefix(16).map { t in
            TabMirror(id: t.id.uuidString,
                      projectName: t.projectName,
                      state: t.state.mirrorLabel,
                      model: t.model,
                      eur: t.eur,
                      tokens: t.tokens,
                      isLive: t.isLive,
                      needsInput: t.needsInput,
                      rateLimitedUntil: t.rateLimitedUntil)
        }
        return ThrottleMirrorSnapshot(
            publishedAt: Date(),
            deviceName: Host.current().localizedName ?? "Mac",
            fiveHour: win(ex?.fiveHour),
            sevenDay: win(ex?.sevenDay),
            sevenDaySonnet: win(ex?.sevenDaySonnet),
            weeklyTokens: weeklyTokens,
            weeklyCostEUR: weeklyCostEUR,
            savedTokensThisWeek: savedTokensThisWeek,
            sessionCount: sessions.count,
            tabs: Array(tabs),
            // Ride the LAN peer secret inside the encrypted blob so the phone can
            // bootstrap the P2P fast path from its first CloudKit sync (no separate
            // record, no schema redeploy).
            peerPairingSecret: PeerTransport.shared.pairingSecretBase64,
            // Off-LAN fallback host (nil unless the user entered one in Settings).
            peerFallbackHost: PeerTransport.shared.fallbackHost,
            // Edge-agent auto-config: the phone's Edge tab configures itself from
            // these instead of asking the user to retype host + 32-char token.
            edgeHost: RemoteSessionsService.shared.isConfigured ? RemoteSessionsService.shared.host : nil,
            edgePort: RemoteSessionsService.shared.isConfigured ? RemoteSessionsService.shared.port : nil,
            edgeToken: RemoteSessionsService.shared.isConfigured ? RemoteSessionsService.shared.token : nil)
    }
}
