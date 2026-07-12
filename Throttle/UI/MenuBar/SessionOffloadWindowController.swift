import AppKit
import SwiftUI

/// Hosts `SessionOffloadSheet` in its own NSWindow. Same reason as
/// `OutputStyleWindowController`: a `.sheet` presented from the menu-bar popover
/// dismisses on the first in-sheet click (NSPopover treats it as "outside") —
/// this sheet needs real clicking/copying/typing, so it can't live in the popover.
@MainActor
final class SessionOffloadWindowController: NSObject {
    static let shared = SessionOffloadWindowController()

    private var window: NSWindow?

    private override init() {}

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.setActivationPolicy(.regular)

        let root = SessionOffloadSheet(onClose: { [weak self] in self?.close() })
        let host = NSHostingController(rootView: root)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Throttle — Run Sessions on Your Server"
        win.isReleasedWhenClosed = false
        win.center()
        win.contentViewController = host
        win.minSize = NSSize(width: 480, height: 480)
        win.delegate = self
        win.setFrameAutosaveName("ThrottleSessionOffloadWindow")

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.performClose(nil)
    }
}

extension SessionOffloadWindowController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
            try? await Task.sleep(for: .milliseconds(100))
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
