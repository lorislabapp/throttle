import UIKit

/// Registers for silent CloudKit pushes and forwards them to the subscriber,
/// which re-fetches the latest mirror snapshot in the background.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        Task { await CloudKitSubscriber.shared.bootstrap() }
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // Silent push → refresh the mirror, then report new data.
        let handler = SendableBox(completionHandler)
        Task {
            await CloudKitSubscriber.shared.fetchLatest()
            handler.value(.newData)
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Pushes unavailable (e.g. Simulator without a paired push token) — the
        // app still works via foreground fetch. Non-fatal.
    }
}

/// Wraps a non-Sendable completion handler so it can cross the Task boundary
/// under Swift 6 strict concurrency. Safe: we only call it once, on the main actor.
private final class SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
