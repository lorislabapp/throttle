import SwiftUI

/// Throttle for Apple Vision Pro — the same read-only mirror of the Mac's live
/// Claude Code usage, as a spatial cockpit. Reuses the iOS mirror services
/// (`MirrorStore`, `CloudKitSubscriber`, `PeerClient`) verbatim; only the surface is
/// spatial. Doctrine unchanged: measure-only, no remote control.
@main
struct ThrottleVisionApp: App {
    @UIApplicationDelegateAdaptor(VisionAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            VisionCockpitView()
        }
        .windowStyle(.plain)
        .defaultSize(width: 900, height: 620)
    }
}
