import AppKit
import SwiftUI

/// AppKit-native window for the Throttle Project view.
///
/// We deliberately bypass SwiftUI's `WindowGroup` / `Window` Scenes because
/// macOS 26.5 has a regression in NSTitlebarBackgroundView's pocket-view
/// rendering that crashes any SwiftUI-managed external window — even with
/// `.windowStyle(.hiddenTitleBar)`. By creating an `NSWindow` ourselves and
/// hosting SwiftUI inside via `NSHostingController`, we sidestep the
/// affected codepath entirely.
///
/// Singleton-ish: `shared.show()` reuses the existing window if it's already
/// open (matching macOS expectations for "Open project window" menu items).
@MainActor
final class ProjectWindowController: NSObject {
    static let shared = ProjectWindowController()

    private var window: NSWindow?
    private weak var appState: AppState?

    private override init() {}

    func show(appState: AppState) {
        self.appState = appState
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = ProjectWindowRoot()
            .environment(appState)
        let host = NSHostingController(rootView: root)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Throttle"
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.center()
        win.contentViewController = host
        win.minSize = NSSize(width: 720, height: 420)
        win.delegate = self

        // Restore frame from defaults if we have one.
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
        }
    }
}
