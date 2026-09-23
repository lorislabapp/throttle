import AppKit
import Foundation

/// Opt-in visual inspection of an already isolated XCTest fixture, never the installed app.
@MainActor
enum HostedViewReview {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["THROTTLE_REVIEW_SCENE"] != nil
    }

    static func prepare(_ window: NSWindow, title: String) {
        guard isEnabled else { return }
        window.styleMask = [.titled, .closable, .resizable]
        window.title = "Throttle QA — \(title) — \(Locale.current.identifier)"
        let dark = ProcessInfo.processInfo.environment["THROTTLE_REVIEW_APPEARANCE"] == "dark"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.center()
        // Match the real cockpit's activation path before testing keyboard focus.
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func hold(_ window: NSWindow?, scene: String) async {
        guard ProcessInfo.processInfo.environment["THROTTLE_REVIEW_SCENE"] == scene,
              let window else { return }
        window.title = "Throttle QA — \(scene) — \(Locale.current.identifier)"
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        FileHandle.standardError.write(Data("THROTTLE_REVIEW_READY: \(scene)\n".utf8))
        // Bound the inspection window even if the reviewer disconnects. Cancellation
        // resumes test cleanup, closing this fixture without touching production windows.
        let deadline = Date().addingTimeInterval(180)
        var previousFocus = ""
        while window.isVisible, Date() < deadline {
            let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            let focus = "active=\(NSApp.isActive) key=\(window.isKeyWindow) "
                + "keyboard=\(NSApp.isFullKeyboardAccessEnabled) responder=\(responder)"
            if focus != previousFocus {
                FileHandle.standardError.write(Data("THROTTLE_REVIEW_FOCUS: \(focus)\n".utf8))
                previousFocus = focus
            }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
    }
}
