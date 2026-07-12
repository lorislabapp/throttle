import SwiftUI
import SwiftTerm
import ThrottleShared

/// On-device SwiftTerm view for an edge-agent session, driven over ttyd
/// (`TtydClient`) rather than the LAN peer link `RemoteTerminalView` uses — a
/// different wire protocol, same rendering approach. Output always flows; input is
/// gated by `TerminalLockState` (starts locked, Face ID to unlock, auto re-lock
/// after 5 min idle) per the non-negotiable write-unlock default.
struct EdgeTerminalView: UIViewRepresentable {
    let session: EdgeAgentService.RemoteSession
    let lockState: TerminalLockState
    var keySender: TerminalKeySender? = nil

    func makeCoordinator() -> Coordinator { Coordinator(lockState: lockState) }

    func makeUIView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero,
                              font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminal = tv

        let svc = EdgeSessionsService.shared
        let geometry = tv.getTerminal()
        Task {
            guard let (port, path) = try? await svc.attach(id: session.id) else { return }
            let client = TtydClient()
            client.onOutput = { [weak coord = context.coordinator] bytes in
                Task { @MainActor in coord?.terminal?.feed(byteArray: bytes[...]) }
            }
            context.coordinator.client = client
            // Accessory-bar keys go through the SAME lock gate as typed input.
            keySender?.send = { [weak client, lockState] bytes in
                guard lockState.unlocked else { return }
                lockState.noteActivity()
                client?.sendInput(bytes)
            }
            client.connect(host: svc.host, port: port, path: path, token: svc.token,
                          cols: geometry.cols, rows: geometry.rows)
        }

        DispatchQueue.main.async { _ = tv.becomeFirstResponder() }
        return tv
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.client?.disconnect()
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        weak var terminal: TerminalView?
        var client: TtydClient?
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

/// Full-screen host for an edge-agent session terminal, with the lock/unlock control.
struct EdgeTerminalScreen: View {
    let session: EdgeAgentService.RemoteSession
    @State private var lockState = TerminalLockState()
    @State private var keySender = TerminalKeySender()
    @State private var unlocking = false

    var body: some View {
        VStack(spacing: 0) {
            if !lockState.unlocked {
                lockBanner
            }
            EdgeTerminalView(session: session, lockState: lockState, keySender: keySender)
                .ignoresSafeArea(.container, edges: .bottom)
            TerminalAccessoryBar(sender: keySender)
        }
        .navigationTitle(session.project)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    unlock()
                } label: {
                    Image(systemName: lockState.unlocked ? "lock.open.fill" : "lock.fill")
                        .foregroundStyle(lockState.unlocked ? MirrorUI.ok : MirrorUI.warn)
                }
                .disabled(unlocking || lockState.unlocked)
            }
        }
        .onChange(of: lockState.unlocked) { _, unlocked in keySender.enabled = unlocked }
    }

    private var lockBanner: some View {
        Button { unlock() } label: {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                Text("Read-only — tap to unlock typing with Face ID")
                    .font(.footnote.weight(.medium))
                Spacer()
                if unlocking { ProgressView() }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(MirrorUI.warn.opacity(0.15))
            .foregroundStyle(MirrorUI.warn)
        }
        .buttonStyle(.plain)
        .disabled(unlocking)
    }

    private func unlock() {
        guard !lockState.unlocked, !unlocking else { return }
        unlocking = true
        Task {
            let ok = await lockState.unlock()
            unlocking = false
            Haptics.tap(ok ? .success : .error)
        }
    }
}
