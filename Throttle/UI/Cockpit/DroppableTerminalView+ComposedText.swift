import SwiftTerm

/// Deliberately a separate file: `DroppableTerminalView.swift` carries the
/// user's uncommitted work, and editing it here would force this task's commit
/// to either sweep in their changes or leave the file half-staged.
extension DroppableTerminalView {

    /// Paste a Throttle-composed prompt into the foreground program. Bracketed
    /// paste when the TUI supports it, so a multi-line prompt arrives as ONE
    /// paste instead of N Enter presses. No newline is ever appended — the user
    /// presses Return.
    ///
    /// This repeats three lines of the private `paste(_:trailingSpace:)` in the
    /// main file rather than calling it, because that method is private and this
    /// extension lives outside its file. Fold the two together once the user's
    /// in-flight edits to that file have landed.
    func insertComposedText(_ text: String) {
        if getTerminal().bracketedPasteMode {
            sendProgrammatic(txt: "\u{1b}[200~" + text + "\u{1b}[201~")
        } else {
            sendProgrammatic(txt: text)
        }
    }
}
