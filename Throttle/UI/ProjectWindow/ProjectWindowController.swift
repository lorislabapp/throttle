import AppKit
import SwiftUI

/// True secondary NSWindow for Throttle's regular Dock application. Throttle
/// previously toggled between `.accessory` and `.regular` around every window;
/// overlapping close animations could demote the still-running app and leave a
/// stale Dock tile. The app now remains regular, while this explicit AppKit window
/// continues to avoid SwiftUI's macOS 26.5 titlebar regression.
///
/// If this still crashes on the next macOS dot release, fall back to
/// the inline mode in DropdownView.Mode.projects.
@MainActor
final class ProjectWindowController: NSObject {
    static let shared = ProjectWindowController()

    private var window: NSWindow?
    private weak var appState: AppState?

    override private init() {}

    func show(appState: AppState, projectID: String? = nil) {
        self.appState = appState
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Idempotent for normal launches and defensive for test/helper launches.
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
            // Keep the regular activation policy so the Dock icon remains a
            // reliable reopen target while the menu-bar process is alive.
        }
    }
}
