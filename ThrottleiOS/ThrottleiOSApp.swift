import SwiftUI

/// Throttle iOS companion — a read-only mirror of the Mac's live Claude Code
/// usage + cockpit state, synced over the user's private CloudKit DB. No remote
/// control (doctrine: measure-only). Standalone value = usage history/trends +
/// cap countdown + threshold alerts, all from the last synced snapshot.
@main
struct ThrottleiOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }
}
