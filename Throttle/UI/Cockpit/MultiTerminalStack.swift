import AppKit
import SwiftTerm
import SwiftUI

/// Hosts EVERY session's terminal at once and shows only the active one.
/// Switching sessions does NOT tear down PTYs — it toggles `isHidden`, so each
/// `claude` keeps running in the background (the whole point of multi-session).
/// Terminals are owned by their `CockpitTab` (retained by the model), so
/// they survive SwiftUI re-renders; this view only reconciles membership,
/// frame, and visibility.
struct MultiTerminalStack: NSViewRepresentable {
    var sessions: [CockpitTab]
    var activeID: UUID?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = CockpitTerminalTheme.backgroundColor.cgColor
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Only SPAWNED tabs have a terminal (dormant restored tabs are nil).
        let spawned = sessions.compactMap { $0.terminal }
        let keep = Set(spawned.map { ObjectIdentifier($0) })

        // Remove terminals whose session is gone.
        for sub in container.subviews where !keep.contains(ObjectIdentifier(sub)) {
            sub.removeFromSuperview()
        }

        let activeTerminal = (sessions.first { $0.id == activeID } ?? sessions.first)?.terminal
        for t in spawned {
            if t.superview !== container {
                t.translatesAutoresizingMaskIntoConstraints = true
                t.autoresizingMask = [.width, .height]
                container.addSubview(t)
            }
            t.frame = container.bounds
            t.isHidden = (t !== activeTerminal)
        }
        // Focus the visible terminal so keystrokes go to the active session.
        if let active = activeTerminal { container.window?.makeFirstResponder(active) }
    }
}
