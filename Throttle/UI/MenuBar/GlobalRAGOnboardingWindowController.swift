import AppKit
import SwiftUI

/// Hosts Global Portfolio Setup in a real macOS window. A sheet attached to
/// MenuBarExtra inherited the popover's immovable/transient behavior and could
/// disappear when local-model work changed focus.
@MainActor
final class GlobalRAGOnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = GlobalRAGOnboardingWindowController()

    private var window: NSWindow?
    private var completion: ((String) -> Void)?

    override private init() {}

    func show(canInstallMCP: Bool, onComplete: @escaping (String) -> Void) {
        completion = onComplete
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(
            rootView: GlobalRAGOnboardingView(
                canInstallMCP: canInstallMCP,
                onRequestClose: { [weak self] in self?.close() },
                onComplete: { [weak self] note in self?.completion?(note) }
            )
        )
        let created = Self.makeWindow(contentViewController: host)
        RetainedWindowPolicy.configure(created, delegate: self)
        created.setFrameAutosaveName("ThrottleGlobalPortfolioSetupWindow")
        created.center()
        window = created
        created.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func makeWindow(contentViewController: NSViewController) -> NSWindow {
        let created = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        created.title = "Throttle — Global Portfolio Setup"
        created.minSize = NSSize(width: 780, height: 590)
        created.isReleasedWhenClosed = false
        created.contentViewController = contentViewController
        return created
    }

    func close() {
        window?.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Retain and reuse the window. Releasing either the NSWindow or the
        // completion graph here caused objc_release crashes on macOS 27.
    }
}
