import SwiftUI

/// Throttle iOS companion — a private mirror of Mac usage/cockpit state plus
/// explicit, authenticated input to an already-running Mac session on the LAN.
/// Standalone value includes local history, countdowns and threshold alerts.
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
