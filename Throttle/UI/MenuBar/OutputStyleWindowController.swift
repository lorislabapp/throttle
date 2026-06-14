import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted when the output-style manager window closes, so the General pane
    /// can refresh its "Active: …" label.
    static let outputStyleChanged = Notification.Name("throttle.outputStyleChanged")
}

/// Hosts the output-style manager in its own NSWindow. A `.sheet` presented from
/// the menu-bar popover dismisses on the first in-sheet click (NSPopover treats
/// the sheet's window as "outside" and closes), so the manager — which needs
/// real clicking, editing, scrolling — must live in a standalone window.
///
/// Mirrors CockpitWindowController's `.accessory` → `.regular` activation switch
/// to dodge the macOS 26.5 NSTitlebar crash for menu-bar (accessory) apps.
@MainActor
final class OutputStyleWindowController: NSObject {
    static let shared = OutputStyleWindowController()

    private var window: NSWindow?

    private override init() {}

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.setActivationPolicy(.regular)

        let root = OutputStyleManagerSheet(onDone: { [weak self] in self?.close() })
        let host = NSHostingController(rootView: root)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Throttle — Output Styles"
        win.isReleasedWhenClosed = false
        win.center()
        win.contentViewController = host
        win.minSize = NSSize(width: 440, height: 420)
        win.delegate = self
        win.setFrameAutosaveName("ThrottleOutputStyleWindow")

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.performClose(nil)
    }
}

extension OutputStyleWindowController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
            NotificationCenter.default.post(name: .outputStyleChanged, object: nil)
            try? await Task.sleep(for: .milliseconds(100))
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
