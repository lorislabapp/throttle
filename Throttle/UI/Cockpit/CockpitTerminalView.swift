import AppKit
import SwiftTerm
import SwiftUI

/// SwiftUI wrapper around SwiftTerm's `LocalProcessTerminalView` — a real
/// PTY-backed terminal. Spawns the user's LOGIN shell so their full PATH is
/// loaded (a GUI app launched from Finder otherwise gets a minimal PATH and
/// can't find `claude`). The user types `claude` in it like any terminal.
///
/// MVP spike for the "Claude Code cockpit" — see the research verdict
/// (NARROW-SCOPE GO): terminal + live meter in one native surface.
struct CockpitTerminalView: NSViewRepresentable {
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: .zero)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        // argv[0] starting with "-" marks a login shell → loads the user's
        // profile → full PATH, so `claude` (and their toolchain) is on PATH.
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        term.startProcess(executable: shell, args: [], environment: env, execName: "-\(shellName)")

        return term
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
