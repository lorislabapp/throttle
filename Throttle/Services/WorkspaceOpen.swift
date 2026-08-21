import AppKit

extension NSWorkspace {
    /// Open a URL without stalling the main thread.
    ///
    /// `NSWorkspace.open(_:)` returns a Bool, and it earns it: the call blocks
    /// until LaunchServices has launched or activated the handling application.
    /// Every call site here is a SwiftUI button action, so that wait happens on
    /// the main thread and the whole window stops responding — including the
    /// menu bar meter, which is the one thing that should never stutter.
    ///
    /// Measured 2026-08-21 on a machine under memory pressure: a single click on
    /// an About-pane link produced a **2.26 s** hang, and the spindump named the
    /// button rather than the browser it was waiting for. That is why it read as
    /// "Throttle keeps crashing" — nothing crashed, the UI simply stopped.
    ///
    /// The completion-handler variant is asynchronous by design: it hands the
    /// request to LaunchServices and returns immediately. Failures are ignored on
    /// purpose — a link that will not open is not worth interrupting the user
    /// over, and the caller has nothing useful to do about it.
    static func openInBackground(_ url: URL) {
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}
