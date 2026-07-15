import SwiftUI
import SwiftTerm

/// On-device SwiftTerm view that drives a live Mac session over the TLS-PSK peer
/// link. Feeds `termOut` bytes into the emulator and forwards the on-screen
/// keyboard back as `termIn`. The heavy differentiators (predictive local echo,
/// resumable stream) land in later increments; this is the raw octet-stream client.
///
/// Requires an established LAN peer link (paired via a CloudKit snapshot). The Mac
/// only accepts the attach if the session is already spawned there — never a spawn
/// or an unauthenticated control path.
struct RemoteTerminalView: UIViewRepresentable {
    /// The Mac cockpit tab id (`TabMirror.id`, a `CockpitTab` UUID string).
    let sessionId: String
    let lockState: TerminalLockState
    let keySender: TerminalKeySender

    func makeCoordinator() -> Coordinator { Coordinator(lockState: lockState) }

    func makeUIView(context: Context) -> TerminalView {
        // Reuse the live view across makeUIView calls (404 engine pattern) —
        // recreating it would re-run PeerClient.attachTerminal and blank the screen.
        if let existing = context.coordinator.cachedView { return existing }
        let tv = TerminalView(frame: .zero,
                              font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        // Never forward mouse events to the remote PTY. When a TUI (claude) turns on
        // any-event mouse tracking (`ESC[?1003h`) and exits without resetting it,
        // SwiftTerm keeps mouseMode on and every touch/scroll emits an SGR motion
        // report into the shared session — echoed as `<btn>;<col>;<row>M` garbage that
        // shows here AND on the Mac cockpit mirroring the same tmux session. Matches the
        // Mac fix in DroppableTerminalView (c6ae798).
        tv.allowMouseReporting = false
        EdgeTerminalView.applyOpaqueBackground(tv)   // same keyboard-reflow fix
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminal = tv
        context.coordinator.cachedView = tv

        // Accessory-bar keys go through the same lock gate as typed input — the LAN
        // terminal types straight into the live Mac session, the most sensitive path.
        keySender.send = { [lockState] bytes in
            guard lockState.unlocked else { return }
            lockState.noteActivity()
            PeerClient.shared.sendTerminalInput(bytes)
        }

        PeerClient.shared.attachTerminal(
            tabID: sessionId,
            onOutput: { [weak coord = context.coordinator] bytes in
                Task { @MainActor in coord?.terminal?.feed(byteArray: bytes[...]) }
            },
            onResize: { [weak coord = context.coordinator] cols, rows in
                // Adopt the Mac's authoritative geometry so wrapping matches.
                Task { @MainActor in coord?.terminal?.getTerminal().resize(cols: cols, rows: rows) }
            })

        return tv
    }

    // Focus (raise the keyboard) only once the write path is unlocked.
    func updateUIView(_ uiView: TerminalView, context: Context) {
        // Anti-ghost-text redraw on keyboard reflow (404 engine fix).
        uiView.setNeedsLayout()
        uiView.setNeedsDisplay()
        if lockState.unlocked, !uiView.isFirstResponder {
            DispatchQueue.main.async { _ = uiView.becomeFirstResponder() }
        } else if !lockState.unlocked, uiView.isFirstResponder {
            DispatchQueue.main.async { _ = uiView.resignFirstResponder() }
        }
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        PeerClient.shared.detachTerminal()
    }

    // SwiftTerm invokes the delegate on the main thread (it's a UIView), so a
    // @MainActor coordinator is runtime-correct; @preconcurrency bridges the
    // protocol's pre-concurrency (non-isolated) declaration under Swift 6.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        weak var terminal: TerminalView?
        /// Strong cache so makeUIView returns the same emulator instance (see makeUIView).
        var cachedView: TerminalView?
        private let lockState: TerminalLockState

        init(lockState: TerminalLockState) { self.lockState = lockState }

        // User typed → ship the bytes to the Mac PTY, but only while unlocked.
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard lockState.unlocked else { return }
            lockState.noteActivity()
            PeerClient.shared.sendTerminalInput(Array(data))
        }
        // Local geometry change (rotation / keyboard) → advise the Mac.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            PeerClient.shared.sendTerminalResize(cols: newCols, rows: newRows)
        }

        // Remaining delegate hooks are not needed by the remote client.
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func bell(source: TerminalView) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    }
}

/// Full-screen host for a remote session terminal. Uses the shared TerminalHost
/// chrome (Face ID lock gate + connection overlay + key bar). The LAN terminal is
/// read-only unless the peer link is actually connected — off-Wi-Fi it says so
/// instead of silently swallowing keystrokes.
struct RemoteTerminalScreen: View {
    let sessionId: String
    let title: String
    @State private var lockState = TerminalLockState()
    @State private var keySender = TerminalKeySender()
    @State private var connection = TerminalConnection()
    private var peer = PeerClient.shared

    // The private `peer` property drags the synthesized memberwise init down to
    // private (broke the Release archive; Debug never built this scheme locally).
    init(sessionId: String, title: String) {
        self.sessionId = sessionId
        self.title = title
    }

    var body: some View {
        TerminalHost(title: title, lockState: lockState, keySender: keySender,
                     connection: connection) {
            RemoteTerminalView(sessionId: sessionId, lockState: lockState, keySender: keySender)
        }
        .onChange(of: peer.connected, initial: true) { _, up in
            connection.state = up ? .live : .readOnly("Off your local network — viewing only. Open this on the same Wi-Fi as your Mac to type.")
        }
    }
}
