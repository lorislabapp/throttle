import SwiftUI

/// Throttle iOS companion — a read-only mirror of the Mac's live Claude Code
/// usage + cockpit state, synced over the user's private CloudKit DB. No remote
/// control (doctrine: measure-only). Standalone value = usage history/trends +
/// cap countdown + threshold alerts, all from the last synced snapshot.
@main
struct ThrottleiOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .onChange(of: scenePhase) { _, phase in
            // Silent pushes are throttled/best-effort; on every foreground pull the
            // latest snapshot and re-kick the LAN link so data is never stale on
            // resume (not just on cold launch).
            guard phase == .active else { return }
            Task {
                await CloudKitSubscriber.shared.fetchLatest()
                if let latest = MirrorStore.shared.latest {
                    PeerClient.shared.syncPairing(from: latest)
                }
            }
        }
    }
}
