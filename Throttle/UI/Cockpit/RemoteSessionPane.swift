import SwiftUI
import SwiftTerm
import ThrottleShared

/// Connection state for a remote (edge-agent) terminal — mirrors the iOS
/// `TerminalConnection` shape, minus the biometric lock: the Mac is the trusted,
/// already-authenticated device driving its own box.
@MainActor
@Observable
final class RemoteTerminalConnection {
    enum State: Equatable { case connecting, live, reconnecting, failed(String) }
    var state: State = .connecting
}

/// The cockpit pane for ONE remote session: a header carrying the REMOTE badge +
/// connection state, above a SwiftTerm view driven over ttyd (`TtydClient`) — the
/// Mac port of iOS's `EdgeTerminalScreen`. Shown as an overlay on the cockpit's
/// terminal area when a remote rail row is selected; local terminals underneath
/// are never torn down.
struct RemoteSessionPane: View {
    let session: EdgeAgentService.RemoteSession
    var onClose: () -> Void = {}

    @State private var connection = RemoteTerminalConnection()
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            MacEdgeTerminalView(session: session, connection: connection, attempt: attempt)
                .background(Color(nsColor: CockpitTerminalTheme.backgroundColor))
            if case .failed(let why) = connection.state {
                HStack(spacing: 8) {
                    Text(why).font(.system(size: 11)).foregroundStyle(.orange)
                    Button("Retry") { attempt += 1 }.controlSize(.small)
                    Spacer()
                }.padding(10)
            }
        }
        .background(Color(nsColor: CockpitTerminalTheme.backgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("REMOTE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(Color.accentColor)
            Text(session.project).font(.system(size: 12.5, weight: .medium))
            stateLabel
            Spacer()
            Button {
                Task { await RemoteSessionsService.shared.act(session.id, "stop"); onClose() }
            } label: { Text("Stop session").font(.system(size: 11)) }
                .controlSize(.small)
            Button { onClose() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }.buttonStyle(.plain).help("Back to local sessions")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder private var stateLabel: some View {
        switch connection.state {
        case .connecting:
            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("connecting…") }
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        case .live:
            HStack(spacing: 5) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text("live · \(session.cwd ?? "")").lineLimit(1)
            }.font(.system(size: 10.5)).foregroundStyle(.secondary)
        case .reconnecting:
            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("reconnecting…") }
                .font(.system(size: 10.5)).foregroundStyle(.orange)
        case .failed:
            Circle().fill(Color.orange).frame(width: 7, height: 7)
        }
    }
}

/// SwiftTerm view attached to an edge-agent session over ttyd. Output feeds the
/// emulator; keystrokes go back through `TtydClient`. Same wire protocol and
/// attach flow as iOS's `EdgeTerminalView`.
private struct MacEdgeTerminalView: NSViewRepresentable {
    let session: EdgeAgentService.RemoteSession
    let connection: RemoteTerminalConnection
    var attempt: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        tv.allowMouseReporting = false   // never forward mouse into the shared tmux
        CockpitTerminalTheme.apply(to: tv)
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminal = tv
        startAttach(context.coordinator, geometry: tv.getTerminal())
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        if context.coordinator.lastAttempt != attempt {
            context.coordinator.lastAttempt = attempt
            context.coordinator.client?.disconnect()
            startAttach(context.coordinator, geometry: nsView.getTerminal())
        }
        if nsView.window?.firstResponder !== nsView {
            DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
        }
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.attachTask?.cancel()
        coordinator.client?.disconnect()
    }

    private func startAttach(_ coord: Coordinator, geometry: Terminal) {
        connection.state = .connecting
        let svc = RemoteSessionsService.shared
        let session = session, connection = connection
        coord.attachTask?.cancel()
        coord.attachTask = Task {
            do {
                let (port, path) = try await EdgeAgentService.attach(
                    baseURL: svc.baseURL, token: svc.token, id: session.id)
                if Task.isCancelled { return }
                let client = TtydClient()
                client.onOutput = { [weak coord] bytes in
                    Task { @MainActor in coord?.terminal?.feed(byteArray: bytes[...]) }
                }
                client.onConnected = { ok in
                    Task { @MainActor in if ok { connection.state = .live } }
                }
                client.onReconnecting = {
                    Task { @MainActor in connection.state = .reconnecting }
                }
                coord.client = client
                client.connect(host: svc.host, port: port, path: path, token: svc.token,
                               cols: geometry.cols, rows: geometry.rows)
            } catch {
                await MainActor.run {
                    connection.state = .failed("Couldn't attach — \(error.localizedDescription)")
                }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        weak var terminal: TerminalView?
        var client: TtydClient?
        var attachTask: Task<Void, Never>?
        var lastAttempt = 0

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            client?.sendInput(Array(data))
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            client?.sendResize(cols: newCols, rows: newRows)
        }
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
