import AppKit
import SwiftUI

/// Hosts the command runner in its own NSWindow — same rationale as
/// `OutputStyleWindowController`: an NSPopover-presented sheet dismisses on the
/// first in-sheet click, and this needs real clicking + text editing. Mirrors
/// the `.accessory` → `.regular` activation switch to dodge the macOS 26.5
/// NSTitlebar crash for menu-bar (accessory) apps.
@MainActor
final class CommandRunnerWindowController: NSObject {
    static let shared = CommandRunnerWindowController()
    private var window: NSWindow?
    private override init() {}

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        NSApp.setActivationPolicy(.regular)
        let root = CommandRunnerSheet(onDone: { [weak self] in self?.close() })
        let host = NSHostingController(rootView: root)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        win.title = "Throttle — Command Runner"
        win.isReleasedWhenClosed = false
        win.center()
        win.contentViewController = host
        win.minSize = NSSize(width: 480, height: 420)
        win.delegate = self
        win.setFrameAutosaveName("ThrottleCommandRunnerWindow")
        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.performClose(nil) }
}

extension CommandRunnerWindowController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
            try? await Task.sleep(for: .milliseconds(100))
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
