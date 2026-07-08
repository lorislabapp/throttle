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
            // Only flip when it actually changes — re-setting isHidden churns the
            // responder chain and makes SwiftTerm spam focus-out/in reports.
            let shouldHide = (t !== activeTerminal)
            if t.isHidden != shouldHide { t.isHidden = shouldHide }
        }
        // Focus the visible terminal so keystrokes go to the active session — but
        // ONLY if it isn't already first responder. updateNSView runs on every
        // re-render (incl. the 10 s stats tick); an unconditional makeFirstResponder
        // resigns + re-acquires focus each time, and with focus-reporting on (Claude
        // Code enables it) that emits a rapid ESC[O/ESC[I pair to the PTY. That focus
        // thrash, landing on an Ink question prompt, auto-confirms the first option.
        // Only reclaim focus for claude when it's ours to reclaim: the current
        // first responder is nil, or a terminal that belongs to THIS stack (e.g. the
        // just-hidden previous tab on a switch). If the user is typing in the side
        // shell — a terminal hosted in the OTHER split pane, not in our subviews —
        // leave it alone, or we'd yank focus back every 10 s stats tick.
        if let active = activeTerminal {
            let fr = container.window?.firstResponder as? NSView
            let frInThisStack = fr != nil && container.subviews.contains { $0 === fr }
            if fr !== active, fr == nil || frInThisStack {
                container.window?.makeFirstResponder(active)
            }
        }
    }
}

/// Hosts the ACTIVE tab's side shell (plain zsh in the project cwd). One at a
/// time — switching tabs re-mounts the new tab's shell; the previous tab's shell
/// keeps running (retained on its `CockpitTab`) until hibernated/closed. Never
/// steals first responder: the user clicks in to type, so it doesn't fight the
/// claude pane for focus.
struct ShellPane: NSViewRepresentable {
    var tab: CockpitTab

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = CockpitTerminalTheme.backgroundColor.cgColor
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let shell = tab.shellTerminal else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        // Drop any stale shell view (previous tab) before mounting the current one.
        for sub in container.subviews where sub !== shell { sub.removeFromSuperview() }
        let justMounted = shell.superview !== container
        if justMounted {
            shell.translatesAutoresizingMaskIntoConstraints = true
            shell.autoresizingMask = [.width, .height]
            container.addSubview(shell)
        }
        shell.frame = container.bounds
        shell.isHidden = false
        // Opening the shell (or switching to a tab whose shell just mounted) means the
        // user wants to type in it — focus it ONCE, on first mount. Async so it lands
        // after MultiTerminalStack's synchronous claude-focus pass on the same render,
        // and only on mount so we never thrash focus every re-render (which historically
        // auto-confirmed claude prompts). Default focus otherwise stays on claude.
        if justMounted {
            DispatchQueue.main.async { shell.window?.makeFirstResponder(shell) }
        }
    }
}
