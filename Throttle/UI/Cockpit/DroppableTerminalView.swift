import AppKit
import SwiftTerm

/// A SwiftTerm terminal that accepts file drops like Terminal.app: dropping one
/// or more files/folders inserts their shell-escaped paths at the cursor,
/// separated by spaces, with a trailing space — never executed. The user can
/// then keep typing (e.g. prefix a command) and press Return themselves.
///
/// SwiftTerm's `LocalProcessTerminalView` does not handle file drops on its own,
/// so we register `.fileURL` (preserving any types SwiftTerm already registered
/// for text-selection drops) and feed the paths to the PTY via `send(txt:)`.
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
        let types = Array(Set(registeredDraggedTypes + [.fileURL]))
        registerForDraggedTypes(types)
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
        let text = urls.map { Self.shellEscape($0.path) }.joined(separator: " ") + " "
        send(txt: text)
        window?.makeFirstResponder(self)
        return true
    }

    /// Single-quote escaping — robust for any path (spaces, $, quotes, globs).
    /// Mirrors the quoting used when the session `cd`s into its project dir.
    static func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
