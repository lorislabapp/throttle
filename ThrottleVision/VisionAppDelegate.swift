import UIKit

/// Registers for silent CloudKit pushes and bootstraps the mirror — same lifecycle
/// as the iOS companion (`ThrottleiOS/AppDelegate`), reused on visionOS.
final class VisionAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        Task { await CloudKitSubscriber.shared.bootstrap() }
        Task { @MainActor in
            if let latest = MirrorStore.shared.latest { PeerClient.shared.syncPairing(from: latest) }
        }
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let handler = VisionSendableBox(completionHandler)
        Task {
            await CloudKitSubscriber.shared.fetchLatest()
            handler.value(.newData)
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Pushes unavailable (e.g. simulator) — foreground fetch still works.
    }
}

private final class VisionSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
