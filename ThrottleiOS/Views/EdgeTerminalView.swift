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
struct EdgeTerminalView: UIViewRepresentable {
    let session: EdgeAgentService.RemoteSession
    let lockState: TerminalLockState
    let keySender: TerminalKeySender
    let connection: TerminalConnection
    /// Bumped by the screen to force a fresh attach on Retry.
    var attempt: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(lockState: lockState) }

    func makeUIView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero,
                              font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        // See RemoteTerminalView: stop SGR mouse-motion reports flooding the shell when
        // a TUI leaves `ESC[?1003h` set on exit. Matches the Mac fix (c6ae798).
        tv.allowMouseReporting = false
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminal = tv
        startAttach(context.coordinator, geometry: tv.getTerminal())
        return tv
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
                    guard lockState.unlocked else { return }
                    lockState.noteActivity()
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

    // Focus only after unlock; also re-drive the attach when `attempt` changes (Retry).
    func updateUIView(_ uiView: TerminalView, context: Context) {
        if context.coordinator.lastAttempt != attempt {
            context.coordinator.lastAttempt = attempt
            context.coordinator.client?.disconnect()
            startAttach(context.coordinator, geometry: uiView.getTerminal())
        }
        if lockState.unlocked, !uiView.isFirstResponder {
            DispatchQueue.main.async { _ = uiView.becomeFirstResponder() }
        } else if !lockState.unlocked, uiView.isFirstResponder {
            DispatchQueue.main.async { _ = uiView.resignFirstResponder() }
        }
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.attachTask?.cancel()
        coordinator.client?.disconnect()
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        weak var terminal: TerminalView?
        var client: TtydClient?
        var attachTask: Task<Void, Never>?
        var lastAttempt = 0
        private let lockState: TerminalLockState

        init(lockState: TerminalLockState) { self.lockState = lockState }

        // User typed → forward only while unlocked; the socket stays connected
        // either way, only input is gated (output/read path is never gated).
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard lockState.unlocked else { return }
            lockState.noteActivity()
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
