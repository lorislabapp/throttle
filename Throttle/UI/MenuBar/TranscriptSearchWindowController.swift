import AppKit
import SwiftUI

/// Hosts the session-search UI in its own NSWindow (same reason as the output-
/// style manager: a menu-bar popover dismisses a sheet on first click). Mirrors
/// the `.accessory` → `.regular` activation switch to dodge the macOS 26.5
/// NSTitlebar crash for menu-bar apps.
@MainActor
final class TranscriptSearchWindowController: NSObject {
    static let shared = TranscriptSearchWindowController()

    private var window: NSWindow?
    private override init() {}

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        NSApp.setActivationPolicy(.regular)

        let host = NSHostingController(rootView: TranscriptSearchView(onDone: { [weak self] in self?.close() }))
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        win.title = "Throttle — Session Search"
        win.isReleasedWhenClosed = false
        win.center()
        win.contentViewController = host
        win.minSize = NSSize(width: 480, height: 360)
        win.delegate = self
        win.setFrameAutosaveName("ThrottleSessionSearchWindow")
        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.performClose(nil) }
}

extension TranscriptSearchWindowController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
            try? await Task.sleep(for: .milliseconds(100))
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
