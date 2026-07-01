import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted when the MCP manager window closes, so any live health view can refresh.
    static let mcpConfigChanged = Notification.Name("throttle.mcpConfigChanged")
}

/// Hosts the MCP-server manager in its own NSWindow — same rationale as
/// `OutputStyleWindowController`: an NSPopover-presented sheet dismisses on the
/// first in-sheet click, and this manager needs real clicking, menus, and text
/// editing. Mirrors the `.accessory` → `.regular` activation switch to dodge the
/// macOS 26.5 NSTitlebar crash for menu-bar (accessory) apps.
@MainActor
final class MCPManagerWindowController: NSObject {
    static let shared = MCPManagerWindowController()

    private var window: NSWindow?

    private override init() {}

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.setActivationPolicy(.regular)

        let root = MCPManagerSheet(onDone: { [weak self] in self?.close() })
        let host = NSHostingController(rootView: root)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Throttle — MCP Servers"
        win.isReleasedWhenClosed = false
        win.center()
        win.contentViewController = host
        win.minSize = NSSize(width: 460, height: 440)
        win.delegate = self
        win.setFrameAutosaveName("ThrottleMCPManagerWindow")

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.performClose(nil)
    }
}

extension MCPManagerWindowController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
            NotificationCenter.default.post(name: .mcpConfigChanged, object: nil)
            try? await Task.sleep(for: .milliseconds(100))
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
