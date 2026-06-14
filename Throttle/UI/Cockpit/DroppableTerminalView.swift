import AppKit
import SwiftTerm

/// A SwiftTerm terminal that accepts file drops like Terminal.app — and, when
/// `claude` is the foreground program, makes a dragged image attach as an inline
/// `[Image #N]` (so Claude can SEE it) instead of a literal path.
///
/// Mechanism (confirmed against Claude Code behaviour):
///  • The drop is fed to the PTY wrapped in a **bracketed paste**
///    (`ESC[200~ … ESC[201~`) whenever the foreground program enabled bracketed
///    paste mode (claude does; so do zsh/bash). That is the signal Claude Code's
///    paste handler uses to run its image-path detection: a recognised image
///    extension (.png/.jpg/.jpeg/.gif/.webp/.bmp/.tiff/.svg) is read from disk
///    and shown as `[Image #N]`. Non-image paths (and shell prompts) just
///    receive the literal text — exactly Terminal.app's behaviour.
///  • Paths are **backslash-escaped**, NOT single-quoted: Claude Code's detector
///    expects bare escaped paths and does not strip surrounding quotes (quoting
///    was why the path showed up verbatim and got "Read" instead of attached).
final class DroppableTerminalView: LocalProcessTerminalView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        enableFileDrops()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        enableFileDrops()
    }

    private func enableFileDrops() {
        // Append .fileURL without clobbering any types SwiftTerm registered.
        registerForDraggedTypes(Array(Set(registeredDraggedTypes + [.fileURL])))
    }

    private func containsFileURLs(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        containsFileURLs(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        containsFileURLs(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: opts) as? [URL], !urls.isEmpty else {
            return super.performDragOperation(sender)
        }
        let escaped = urls.map { Self.terminalEscape($0.path) }.joined(separator: " ")

        // Bracketed paste → the foreground program treats this as a paste and
        // runs paste-time handling (claude → [Image #N] for image files).
        // Fall back to raw bytes if bracketed paste isn't enabled, so we never
        // dump a literal "[200~".
        let payload: String
        if getTerminal().bracketedPasteMode {
            payload = "\u{1b}[200~" + escaped + "\u{1b}[201~"
        } else {
            payload = escaped + " "
        }
        send(txt: payload)
        window?.makeFirstResponder(self)
        return true
    }

    /// Backslash-escape shell/Claude-significant characters, matching how
    /// Terminal.app & Finder escape paths on drag.
    static func terminalEscape(_ path: String) -> String {
        let special: Set<Character> = [
            " ", "\t", "\"", "'", "\\", "(", ")", "[", "]", "{", "}",
            "<", ">", "|", ";", "&", "$", "`", "*", "?", "!", "#", "~",
        ]
        var out = ""
        out.reserveCapacity(path.count + 8)
        for ch in path {
            if special.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}
