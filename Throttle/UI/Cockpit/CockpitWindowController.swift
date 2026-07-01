import AppKit
import SwiftUI

/// Secondary NSWindow hosting the cockpit (live meter strip + terminal running
/// `claude`). Mirrors `ProjectWindowController`'s `.accessory` → `.regular`
/// activation-policy switch, which dodges the macOS 26.5 NSTitlebar crash that
/// fires when a menu-bar (accessory) app creates a titled window.
@MainActor
final class CockpitWindowController: NSObject {
    static let shared = CockpitWindowController()

    private var window: NSWindow?
    private weak var appState: AppState?

    private override init() {}

    private static let alwaysOnTopKey = "cockpitAlwaysOnTop"
    /// Opt-in: keep the Cockpit window floating above other apps (a companion you
    /// watch while working). OFF by default; setter applies to the live window.
    static var alwaysOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: alwaysOnTopKey) }
        set { UserDefaults.standard.set(newValue, forKey: alwaysOnTopKey); shared.applyLevel() }
    }

    private func applyLevel() { window?.level = Self.alwaysOnTop ? .floating : .normal }

    func show(appState: AppState) {
        self.appState = appState
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            applyLevel()
            return
        }

        NSApp.setActivationPolicy(.regular)

        let root = MultiCockpitRoot().environment(appState)
        let host = NSHostingController(rootView: root)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Throttle — Cockpit"
        win.isReleasedWhenClosed = false
        win.center()
        win.contentViewController = host
        win.minSize = NSSize(width: 640, height: 400)
        win.delegate = self
        win.setFrameAutosaveName("ThrottleCockpitWindow")

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        applyLevel()
    }

    func close() {
        window?.performClose(nil)
    }
}

extension CockpitWindowController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
            try? await Task.sleep(for: .milliseconds(100))
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
