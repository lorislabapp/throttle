import AppKit
import SwiftUI

/// Secondary NSWindow hosting the cockpit (live meter strip + terminal running
/// a coding agent). Throttle stays a regular Dock application for its lifetime:
/// demoting to `.accessory` on close left a stale Dock tile that could launch a
/// doomed second instance while the menu-bar process was still alive.
@MainActor
final class CockpitWindowController: NSObject {
    static let shared = CockpitWindowController()

    private var window: NSWindow?
    private weak var appState: AppState?

    override private init() {}

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

/// Dedicated evidence window used by the Portfolio inspector. Keeping this out
/// of the menu-bar navigation means a graph node can open a Vault query without
/// dismissing or rebuilding the cockpit and its live terminals.
@MainActor
final class ResearchVaultWindowController: NSObject, NSWindowDelegate {
    static let shared = ResearchVaultWindowController()
    private var window: NSWindow?

    override private init() {}

    func show(query: String) {
        let host = NSHostingController(
            rootView: ResearchVaultWorkbenchView(initialQuery: query, onBack: { [weak self] in
                self?.window?.performClose(nil)
            })
        )
        if let window {
            window.contentViewController = host
            window.makeKeyAndOrderFront(nil)
        } else {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 540),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            created.title = "Throttle — Research Vault"
            created.minSize = NSSize(width: 720, height: 460)
            created.contentViewController = host
            created.delegate = self
            created.center()
            created.makeKeyAndOrderFront(nil)
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in self.window = nil }
    }
}

extension CockpitWindowController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
        }
    }
}
