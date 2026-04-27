import SwiftUI

@main
struct ThrottleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            DropdownView()
                .environment(appDelegate.appState)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsScene()
                .environment(appDelegate.appState)
        }

        Window("Welcome to Throttle", id: "first-run") {
            FirstRunWindow()
                .environment(appDelegate.appState)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Throttle Logs", id: "logs") {
            LogViewerWindow()
        }
        .windowResizability(.contentSize)
    }
}
