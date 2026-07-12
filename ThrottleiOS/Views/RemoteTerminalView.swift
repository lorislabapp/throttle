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
    var keySender: TerminalKeySender? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero,
                              font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminal = tv

        keySender?.send = { bytes in PeerClient.shared.sendTerminalInput(bytes) }

        PeerClient.shared.attachTerminal(
            tabID: sessionId,
            onOutput: { [weak coord = context.coordinator] bytes in
                Task { @MainActor in coord?.terminal?.feed(byteArray: bytes[...]) }
            },
            onResize: { [weak coord = context.coordinator] cols, rows in
                // Adopt the Mac's authoritative geometry so wrapping matches.
                Task { @MainActor in coord?.terminal?.getTerminal().resize(cols: cols, rows: rows) }
            })

        DispatchQueue.main.async { _ = tv.becomeFirstResponder() }
        return tv
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        PeerClient.shared.detachTerminal()
    }

    // SwiftTerm invokes the delegate on the main thread (it's a UIView), so a
    // @MainActor coordinator is runtime-correct; @preconcurrency bridges the
    // protocol's pre-concurrency (non-isolated) declaration under Swift 6.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        weak var terminal: TerminalView?

        // User typed → ship the bytes to the Mac PTY.
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
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

/// Full-screen host for a remote session terminal.
struct RemoteTerminalScreen: View {
    let sessionId: String
    let title: String
    @State private var keySender = TerminalKeySender()

    var body: some View {
        VStack(spacing: 0) {
            RemoteTerminalView(sessionId: sessionId, keySender: keySender)
                .ignoresSafeArea(.container, edges: .bottom)
            TerminalAccessoryBar(sender: keySender)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
