import AppKit
import SwiftUI

/// True secondary NSWindow for menu-bar apps. The trick that makes it
/// work on macOS 26.5 (where direct NSWindow creation from a status-
/// item context crashes inside NSTitlebarBackgroundView) is the
/// activation-policy switch:
///
///   1. Throttle launches as `.accessory` (LSUIElement = 1 → no Dock).
///   2. Right before showing the project window we flip to `.regular`
///      so the app is treated as a normal foreground app — that
///      avoids the broken codepath that fires only for titled NSWindows
///      created from accessory apps.
///   3. When the window closes we flip back to `.accessory` so the
///      Dock icon disappears again.
///
/// If this still crashes on the next macOS dot release, fall back to
/// the inline mode in DropdownView.Mode.projects.
@MainActor
final class ProjectWindowController: NSObject {
    static let shared = ProjectWindowController()

    private var window: NSWindow?
    private weak var appState: AppState?

    private override init() {}

    func show(appState: AppState, projectID: String? = nil) {
        self.appState = appState
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Step 1: become a real foreground app for the duration of the
        // window. This is what dodges the macOS 26.5 NSTitlebar crash.
        NSApp.setActivationPolicy(.regular)

        let root = ProjectWindowRoot(onBack: { [weak self] in
            self?.close()
        }, initialProjectID: projectID)
        .environment(appState)
        let host = NSHostingController(rootView: root)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Throttle — Project window"
        win.isReleasedWhenClosed = false
        win.center()
        win.contentViewController = host
        win.minSize = NSSize(width: 720, height: 420)
        win.delegate = self

        win.setFrameAutosaveName("ThrottleProjectWindow")

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.performClose(nil)
    }
}

extension ProjectWindowController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
            // Step 3: back to accessory so the Dock icon disappears.
            // Defer slightly so AppKit can finish its close animation.
            try? await Task.sleep(for: .milliseconds(100))
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
