import Foundation
import ThrottlePeer
import ThrottleShared

/// The existing terminal boundary, injectable without creating a PTY or cockpit.
@MainActor
protocol PeerBridgeTerminal: AnyObject {
    var onOutputBytes: (@MainActor ([UInt8]) -> Void)? { get set }
    var peerGeometry: (cols: Int, rows: Int) { get }
    func injectRemoteInput(_ bytes: [UInt8])
}

extension DroppableTerminalView: PeerBridgeTerminal {
    var peerGeometry: (cols: Int, rows: Int) {
        let terminal = getTerminal()
        return (terminal.cols, terminal.rows)
    }
}

/// App-layer glue for the remote terminal: routes peer control frames
/// (`termAttach`/`termIn`/`termResize`/`termDetach`) between the Mac's
/// `PeerAdvertiser` (via `PeerTransport`) and the live cockpit sessions
/// (`MultiCockpitModel` + `DroppableTerminalView`).
///
/// Doctrine: this is deliberate, opt-in remote control — a paired phone drives a
/// session that already runs on the Mac. It is gated on the authenticated TLS-PSK
/// peer link (no unauthenticated control path) and only ever attaches to a session
/// that is **already spawned** locally; it never spawns, kills, or resizes the Mac's
/// own terminal (the Mac stays authoritative on geometry).
@MainActor
final class PeerTerminalBridge {
    static let shared = PeerTerminalBridge()
    private let permitsControl: () -> Bool
    private let resolveTerminal: (UUID) -> (any PeerBridgeTerminal)?
    private let sendOutput: ([UInt8], PeerClientID) -> Void
    private let sendResize: (Int, Int, PeerClientID) -> Void

    private convenience init() {
        self.init(
            permitsControl: { PeerTransport.shared.permitsTerminalControl },
            resolveTerminal: { id in
                MultiCockpitModel.shared.sessions.first { $0.id == id }?.terminal as? DroppableTerminalView
            },
            sendOutput: { PeerTransport.shared.sendTerminalOutput($0, to: $1) },
            sendResize: { PeerTransport.shared.sendTerminalResize(cols: $0, rows: $1, to: $2) }
        )
    }

    /// Test construction supplies all effects explicitly; it never reads shared.
    init(permitsControl: @escaping () -> Bool,
         resolveTerminal: @escaping (UUID) -> (any PeerBridgeTerminal)?,
         sendOutput: @escaping ([UInt8], PeerClientID) -> Void,
         sendResize: @escaping (Int, Int, PeerClientID) -> Void) {
        self.permitsControl = permitsControl
        self.resolveTerminal = resolveTerminal
        self.sendOutput = sendOutput
        self.sendResize = sendResize
    }

    /// client → the cockpit tab it's attached to.
    private var clientTab: [PeerClientID: UUID] = [:]
    /// tab → the set of clients tapping its output (fan-out target).
    private var tabClients: [UUID: Set<PeerClientID>] = [:]
    /// Per-client streaming mouse-report filter: an old phone build (or any client
    /// still forwarding mouse events into a stuck `ESC[?1003h` session) floods the
    /// PTY with SGR reports that echo as `35;150;30M…` garbage in claude's input.
    /// A remote KEYBOARD never produces these, so stripping is lossless. Stateful
    /// per client — a report can split across peer frames.
    private var inputFilters: [PeerClientID: MouseReportFilter] = [:]

    /// Entry point wired from `PeerTransport` (hops here on the main actor).
    func handle(_ control: PeerTerminalControl, from client: PeerClientID) {
        guard permitsControl() else { reset(); return }
        switch control {
        case .attach(let sessionId): attach(client, to: sessionId)
        case .input(let bytes):      inject(bytes, from: client)
        case .resize:                break   // Mac authoritative — phone adapts, we don't resize locally
        case .detach:                detach(client)
        }
    }

    /// Drop all taps (called when the LAN transport stops).
    func reset() {
        for tabID in tabClients.keys { terminal(for: tabID)?.onOutputBytes = nil }
        clientTab.removeAll()
        tabClients.removeAll()
        inputFilters.removeAll()
    }

    // MARK: - private

    private func attach(_ client: PeerClientID, to sessionId: String) {
        guard let uuid = UUID(uuidString: sessionId),
              let term = terminal(for: uuid) else { return }   // only attach to a spawned tab
        // Moving to another session must stop the old output subscription.
        detach(client)
        clientTab[client] = uuid
        tabClients[uuid, default: []].insert(client)

        // One broadcast closure per terminal, fanning to every attached client.
        term.onOutputBytes = { [weak self] bytes in
            guard let self, let clients = self.tabClients[uuid] else { return }
            for client in clients { self.sendOutput(bytes, client) }
        }
        // Tell the phone the Mac's authoritative geometry so it sizes its emulator.
        let geometry = term.peerGeometry
        sendResize(geometry.cols, geometry.rows, client)
    }

    private func inject(_ bytes: [UInt8], from client: PeerClientID) {
        guard permitsControl() else { reset(); return }
        guard let uuid = clientTab[client], let term = terminal(for: uuid) else { return }
        var filter = inputFilters[client] ?? MouseReportFilter()
        let clean = filter.filter(bytes)
        inputFilters[client] = filter
        term.injectRemoteInput(clean)
    }

    private func detach(_ client: PeerClientID) {
        inputFilters[client] = nil
        guard let uuid = clientTab.removeValue(forKey: client) else { return }
        tabClients[uuid]?.remove(client)
        if tabClients[uuid]?.isEmpty ?? true {
            tabClients[uuid] = nil
            terminal(for: uuid)?.onOutputBytes = nil   // last client gone → stop the tap
        }
    }

    private func terminal(for tabID: UUID) -> (any PeerBridgeTerminal)? {
        resolveTerminal(tabID)
    }
}
