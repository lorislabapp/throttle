import AppKit
import SwiftTerm
import SwiftUI

/// Holds a weak reference to the live terminal so other cockpit surfaces (the
/// Sessions panel) can type a command into it — e.g. `claude --resume <id>`.
/// This is a passthrough: we never store or manage session state ourselves;
/// Claude Code owns resume. One terminal, no tabs.
@MainActor
final class CockpitTerminalController {
    fileprivate weak var terminal: LocalProcessTerminalView?

    /// Type `command` into the terminal and press return. No-op if the terminal
    /// isn't ready yet.
    func run(_ command: String) {
        terminal?.send(txt: command + "\n")
    }
}

/// SwiftUI wrapper around SwiftTerm's `LocalProcessTerminalView` — a real
/// PTY-backed terminal. Spawns the user's LOGIN shell so their full PATH is
/// loaded (a GUI app launched from Finder otherwise gets a minimal PATH and
/// can't find `claude`). The user types `claude` in it like any terminal.
///
/// Part of the "Claude Code cockpit" — the terminal is a commodity container;
/// the decision layer around it is the product (NARROW-SCOPE GO).
struct CockpitTerminalView: NSViewRepresentable {
    var controller: CockpitTerminalController?

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: .zero)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        // argv[0] starting with "-" marks a login shell → loads the user's
        // profile → full PATH, so `claude` (and their toolchain) is on PATH.
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        term.startProcess(executable: shell, args: [], environment: env, execName: "-\(shellName)")

        controller?.terminal = term
        return term
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
