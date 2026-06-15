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

    /// UserDefaults flag: drop images as locally-OCR'd TEXT (cheap) instead of
    /// as `[Image #N]` (costly vision tokens). Hold Option while dropping to
    /// flip the choice for one drop.
    static let ocrDefaultsKey = "cockpitDropImagesAsText"

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: opts) as? [URL], !urls.isEmpty else {
            return super.performDragOperation(sender)
        }

        let ocrDefault = UserDefaults.standard.bool(forKey: Self.ocrDefaultsKey)
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        let useOCR = (ocrDefault != optionHeld) && urls.contains(where: { ImageTextExtractor.isImage($0) })

        if useOCR {
            // OCR is synchronous and can take 100s of ms — run it off-main, then
            // paste the recognised text (with non-image paths kept as paths).
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let pieces: [String] = urls.map { u in
                    if ImageTextExtractor.isImage(u), let text = ImageTextExtractor.extractText(from: u) {
                        return "[image: \(u.lastPathComponent)]\n\(text)"
                    }
                    return Self.terminalEscape(u.path)
                }
                let joined = pieces.joined(separator: "\n\n")
                DispatchQueue.main.async { self?.paste(joined) }
            }
            window?.makeFirstResponder(self)
            return true
        }

        // Default: shell-escaped paths (claude turns image paths into [Image #N]).
        paste(urls.map { Self.terminalEscape($0.path) }.joined(separator: " "), trailingSpace: true)
        window?.makeFirstResponder(self)
        return true
    }

    /// Feed text to the PTY as a bracketed paste when the foreground program
    /// supports it (claude does), else raw bytes — never a literal "[200~".
    private func paste(_ text: String, trailingSpace: Bool = false) {
        if getTerminal().bracketedPasteMode {
            send(txt: "\u{1b}[200~" + text + "\u{1b}[201~")
        } else {
            send(txt: text + (trailingSpace ? " " : ""))
        }
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
