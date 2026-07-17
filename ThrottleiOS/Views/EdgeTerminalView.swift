import SwiftUI
import SwiftTerm
import ThrottleShared

/// On-device SwiftTerm view for an edge-agent session, driven over ttyd
/// (`TtydClient`) rather than the LAN peer link `RemoteTerminalView` uses — a
/// different wire protocol, same rendering approach. Output always flows; input is
/// gated by `TerminalLockState` (starts locked, Face ID to unlock, auto re-lock
/// after 5 min idle) per the non-negotiable write-unlock default. Connection state
/// is surfaced through `TerminalConnection` so a failed attach never leaves a blank
/// terminal with no explanation.
/// TerminalView that drops first-responder when it leaves the window. SwiftUI's
/// TabView keeps non-selected tabs' hierarchies alive, so without this the
/// terminal stays firstResponder after a bottom-tab switch and SwiftTerm's
/// keyboard accessory bar (esc/ctrl/arrows) sticks over EVERY tab.
final class ResigningTerminalView: TerminalView {
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil, isFirstResponder { _ = resignFirstResponder() }
    }
}

struct EdgeTerminalView: UIViewRepresentable {
    let session: EdgeAgentService.RemoteSession
    let lockState: TerminalLockState
    let keySender: TerminalKeySender
    let connection: TerminalConnection
    /// Bumped by the screen to force a fresh attach on Retry.
    var attempt: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(lockState: lockState) }

    func makeUIView(context: Context) -> TerminalView {
        // Reuse the live view across makeUIView calls (404's SwiftTermSSHView
        // pattern): SwiftUI can rebuild the representable on keyboard/rotation
        // churn, and recreating the emulator would drop the screen AND re-attach
        // the socket mid-session.
        if let existing = context.coordinator.cachedView { return existing }
        let tv = ResigningTerminalView(frame: .zero,
                                       font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        // See RemoteTerminalView: stop SGR mouse-motion reports flooding the shell when
        // a TUI leaves `ESC[?1003h` set on exit. Matches the Mac fix (c6ae798).
        tv.allowMouseReporting = false
        Self.applyOpaqueBackground(tv)
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminal = tv
        context.coordinator.cachedView = tv
        startAttach(context.coordinator, geometry: tv.getTerminal())
        return tv
    }

    /// Opaque black background so keyboard-driven reflows don't leave transparent
    /// gaps where the previous (wider) rendering bleeds through — ported from 404's
    /// terminal engine, where this fixed the "can't see anything" rendering bugs.
    static func applyOpaqueBackground(_ tv: TerminalView) {
        tv.isOpaque = true
        tv.backgroundColor = .black
        tv.clearsContextBeforeDrawing = true
    }

    private func startAttach(_ coord: Coordinator, geometry: Terminal) {
        connection.state = .connecting
        let svc = EdgeSessionsService.shared
        let session = session, keySender = keySender, lockState = lockState, connection = connection
        coord.attachTask?.cancel()
        coord.attachTask = Task {
            do {
                let (port, path) = try await svc.attach(id: session.id)
                if Task.isCancelled { return }
                let client = TtydClient()
                client.onOutput = { [weak coord] bytes in
                    Task { @MainActor in coord?.terminal?.feed(byteArray: bytes[...]) }
                }
                client.onConnected = { ok in
                    Task { @MainActor in connection.state = ok ? .live : connection.state }
                }
                client.onReconnecting = {
                    Task { @MainActor in connection.state = .reconnecting }
                }
                coord.client = client
                keySender.send = { [weak client] bytes in
                    guard lockState.unlocked else { lockState.requestUnlockForTyping(); return }
                    client?.sendInput(bytes)
                }
                client.connect(host: svc.host, port: port, path: path, token: svc.token,
                               cols: geometry.cols, rows: geometry.rows)
            } catch {
                await MainActor.run {
                    connection.state = .failed("Couldn't reach the session — check the box and your Tailscale connection.")
                }
            }
        }
    }

    // Re-drive the attach when `attempt` changes (Retry). Focus is left to SwiftTerm's
    // own tap-to-focus, exactly as 404 does it — the previous code only raised the
    // keyboard once `lockState.unlocked` flipped, which with a locked default meant
    // the keyboard never appeared at all.
    func updateUIView(_ uiView: TerminalView, context: Context) {
        // Keyboard show/hide reflows the buffer but can leave stale cell rects
        // painted (ghost text from the previous, wider layout). Force a full
        // redraw on every update — same fix as 404's terminal engine.
        uiView.setNeedsLayout()
        uiView.setNeedsDisplay()
        if context.coordinator.lastAttempt != attempt {
            context.coordinator.lastAttempt = attempt
            context.coordinator.client?.disconnect()
            startAttach(context.coordinator, geometry: uiView.getTerminal())
        }
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        if uiView.isFirstResponder { _ = uiView.resignFirstResponder() }
        coordinator.attachTask?.cancel()
        coordinator.client?.disconnect()
        coordinator.cachedView = nil
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        weak var terminal: TerminalView?
        /// Strong cache so makeUIView returns the same emulator instance for the
        /// coordinator's whole lifetime (see makeUIView).
        var cachedView: TerminalView?
        var client: TtydClient?
        var attachTask: Task<Void, Never>?
        var lastAttempt = 0
        private let lockState: TerminalLockState

        init(lockState: TerminalLockState) { self.lockState = lockState }

        // User typed → forward. If the session was deliberately locked, ask to unlock
        // rather than eat the keystroke: silent-drop is exactly what made this look
        // broken on iOS.
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard lockState.unlocked else { lockState.requestUnlockForTyping(); return }
            client?.sendInput(Array(data))
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            client?.sendResize(cols: newCols, rows: newRows)
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

/// Full-screen host for an edge-agent session terminal.
struct EdgeTerminalScreen: View {
    let session: EdgeAgentService.RemoteSession
    @State private var lockState = TerminalLockState()
    @State private var keySender = TerminalKeySender()
    @State private var connection = TerminalConnection()
    @State private var attempt = 0

    var body: some View {
        TerminalHost(title: session.project, lockState: lockState, keySender: keySender,
                     connection: connection, onRetry: { attempt += 1 }) {
            EdgeTerminalView(session: session, lockState: lockState, keySender: keySender,
                             connection: connection, attempt: attempt)
        }
    }
}
