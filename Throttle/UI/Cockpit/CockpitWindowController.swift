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
        win.center()
        win.contentViewController = host
        win.minSize = NSSize(width: 640, height: 400)
        RetainedWindowPolicy.configure(win, delegate: self)
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

/// Dedicated evidence window shared by the menu bar and Portfolio inspector.
/// The workbench needs a real resizable window: its source and import controls
/// are intentionally richer than a menu-bar popover can present accessibly.
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
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Without this the window opens while the app is still an accessory, so
        // it carries no application menu bar and the user cannot reach Throttle's
        // own menu at all. Every other window in the app does this; this one was
        // the exception. It also dodges the macOS 26.5 NSTitlebar crash that hits
        // menu-bar apps creating titled windows.
        NSApp.setActivationPolicy(.regular)

        // ResearchVaultWorkbenchView declares minWidth 920, idealWidth 1100 and
        // minHeight 600. The window was built at 820x520 with a 760x480 floor —
        // below the content's own minimum — so SwiftUI had no option but to clip,
        // and the intake controls were cut off at both edges. Match the view.
        let created = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        created.title = "Throttle — Research Vault"
        created.minSize = NSSize(width: 940, height: 620)
        created.contentViewController = host
        RetainedWindowPolicy.configure(created, delegate: self)
        created.center()
        // Remember where the user put it and how big they made it.
        created.setFrameAutosaveName("ThrottleResearchVaultWindow")
        created.makeKeyAndOrderFront(nil)
        window = created
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Retained by the singleton and reused on the next search.
    }
}

extension CockpitWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Retained by the singleton and reused on the next open.
    }
}
