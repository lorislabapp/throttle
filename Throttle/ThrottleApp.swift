import SwiftUI

@main
struct ThrottleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The MenuBarExtra dropdown hosts ALL of the app's UI:
        //   - Meter (default mode)
        //   - First-run flow (when firstRunDone == false)
        //   - Inline Settings (4 sub-tabs: General / Calibration / Hooks / Privacy)
        //   - About (with the 10-tap dev-unlock gesture on the version string)
        //
        // We deliberately don't ship any other Scene (Settings, Window, WindowGroup)
        // because macOS 26.5 has a regression in NSTitlebarBackgroundView's
        // pocket-view rendering that crashes any SwiftUI-managed external window —
        // even with .windowStyle(.hiddenTitleBar). Keeping everything inside the
        // popover avoids that code path entirely.
        MenuBarExtra {
            DropdownView()
                .environment(appDelegate.appState)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.appState)
        }
        .menuBarExtraStyle(.window)
    }
}
