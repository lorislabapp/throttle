import Foundation
import ThrottlePeer
import ThrottleShared

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
    private init() {}

    private var model: MultiCockpitModel { .shared }

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
        clientTab[client] = uuid
        tabClients[uuid, default: []].insert(client)

        // One broadcast closure per terminal, fanning to every attached client.
        term.onOutputBytes = { [weak self] bytes in
            guard let self, let clients = self.tabClients[uuid] else { return }
            for c in clients { PeerTransport.shared.sendTerminalOutput(bytes, to: c) }
        }
        // Tell the phone the Mac's authoritative geometry so it sizes its emulator.
        let t = term.getTerminal()
        PeerTransport.shared.sendTerminalResize(cols: t.cols, rows: t.rows, to: client)
    }

    private func inject(_ bytes: [UInt8], from client: PeerClientID) {
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

    private func terminal(for tabID: UUID) -> DroppableTerminalView? {
        model.sessions.first { $0.id == tabID }?.terminal as? DroppableTerminalView
    }
}
