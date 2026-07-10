import Foundation
import Network

/// Mac side of the LAN mirror: advertises `_throttle._tcp` over Bonjour, accepts
/// TLS-PSK connections from the iOS companion, and pushes the latest encoded
/// `ThrottleMirrorSnapshot` to every connected peer sub-second.
///
/// Measure-only: this only *serves* the read-only snapshot. It reads nothing back
/// from peers except a `hello` (device name) and heartbeats; there is no control
/// path. Fail-open like `TraycerReceiver` — any bind/advertise failure disables the
/// link quietly and CloudKit remains the fallback transport.
///
/// `@unchecked Sendable`: all mutable state (`listener`, `conns`, `latest`, `seq`)
/// is confined to the serial queue `q`; handlers hop back onto it. Callers touch
/// only `start`/`stop`/`publish`, which marshal onto `q`.
public final class PeerAdvertiser: @unchecked Sendable {

    private let secret: PeerPairingSecret
    private let serviceName: String
    private let q = DispatchQueue(label: "throttle.peer.advertiser")

    /// Per-connection state confined to `q`: the socket, a stream buffer for frame
    /// reassembly, and a stable `PeerClientID` the app layer uses to address it.
    /// `@unchecked Sendable`: like the enclosing advertiser, every access is confined
    /// to the serial queue `q`, so the mutable `buffer` is never touched concurrently.
    private final class Conn: @unchecked Sendable {
        let nw: NWConnection
        let id: PeerClientID
        var buffer = Data()
        init(nw: NWConnection, id: PeerClientID) { self.nw = nw; self.id = id }
    }

    private var listener: NWListener?
    private var conns: [ObjectIdentifier: Conn] = [:]
    private var byClient: [PeerClientID: ObjectIdentifier] = [:]
    private var nextClientRaw: UInt64 = 0
    private var latest: Data?
    private var seq: UInt32 = 0

    /// Fired on `q` when a peer sends a terminal control frame (attach/input/resize/
    /// detach), and once with `.detach` when a peer disconnects. The app-layer
    /// `PeerTerminalBridge` sets this and hops to `@MainActor` to touch the cockpit.
    /// Unset by default → pure measure-only mirror, no control path (back-compat).
    public var onTerminalControl: (@Sendable (PeerTerminalControl, PeerClientID) -> Void)?

    /// - Parameters:
    ///   - secret: the CloudKit-shared pairing secret (derives the TLS-PSK).
    ///   - serviceName: Bonjour instance name (e.g. the Mac's `Host` name).
    public init(secret: PeerPairingSecret, serviceName: String) {
        self.secret = secret
        self.serviceName = serviceName
    }

    /// Bind + advertise. Never throws — a failure just leaves the link disabled.
    public func start() {
        q.async { [self] in
            guard listener == nil else { return }
            let params = PeerTLS.parameters(secret: secret)
            guard let l = try? NWListener(using: params) else {
                NSLog("[PeerAdvertiser] bind failed — LAN mirror disabled (CloudKit still active)")
                return
            }
            l.service = NWListener.Service(name: serviceName, type: PeerPairing.serviceType)
            l.stateUpdateHandler = { [weak self] state in
                // Runs on `q` (listener started with queue: q) — call teardown directly.
                if case .failed = state { self?.teardown() }
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: q)
            listener = l
        }
    }

    public func stop() { q.async { [self] in teardown() } }

    /// Push the freshest snapshot (already `encoded()`) to all peers. Cheap; safe on
    /// every `AppState.refresh`.
    public func publish(_ snapshotData: Data) {
        q.async { [self] in
            latest = snapshotData
            let frame = nextFrame(kind: .snapshot, payload: snapshotData)
            for c in conns.values { c.nw.send(content: frame, completion: .contentProcessed { _ in }) }
        }
    }

    // MARK: - remote terminal (Mac→peer sends)

    /// Send raw PTY output to a specific attached peer. No-op if it has disconnected.
    public func sendTerminalOutput(_ bytes: [UInt8], to client: PeerClientID) {
        guard !bytes.isEmpty else { return }
        q.async { [self] in
            guard let oid = byClient[client], let c = conns[oid] else { return }
            c.nw.send(content: nextFrame(kind: .termOut, payload: Data(bytes)),
                      completion: .contentProcessed { _ in })
        }
    }

    /// Tell a peer the Mac terminal's authoritative geometry (Mac→phone `termResize`),
    /// so the phone can size its emulator to match on attach.
    public func sendTerminalResize(cols: Int, rows: Int, to client: PeerClientID) {
        q.async { [self] in
            guard let oid = byClient[client], let c = conns[oid] else { return }
            c.nw.send(content: nextFrame(kind: .termResize, payload: PeerTerminal.resizePayload(cols: cols, rows: rows)),
                      completion: .contentProcessed { _ in })
        }
    }

    // MARK: - private (all on q)

    private func teardown() {
        listener?.cancel(); listener = nil
        for c in conns.values { c.nw.cancel() }
        conns.removeAll()
        byClient.removeAll()
    }

    private func nextFrame(kind: PeerMessage.Kind, payload: Data) -> Data {
        seq &+= 1
        return PeerMessage(kind: kind, seq: seq, timestampMillis: PeerTLS.nowMillis(), payload: payload).encoded()
    }

    private func accept(_ conn: NWConnection) {
        let oid = ObjectIdentifier(conn)
        nextClientRaw &+= 1
        let client = PeerClientID(raw: nextClientRaw)
        let entry = Conn(nw: conn, id: client)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // Greet + immediately send the current snapshot so a fresh peer isn't
                // blank until the next refresh.
                let hello = self.nextFrame(kind: .hello, payload: Data(self.serviceName.utf8))
                conn.send(content: hello, completion: .contentProcessed { _ in })
                if let snap = self.latest {
                    conn.send(content: self.nextFrame(kind: .snapshot, payload: snap),
                              completion: .contentProcessed { _ in })
                }
                self.receiveLoop(entry)   // parse frames; route terminal control, keep alive
            case .failed, .cancelled:
                // Tell the bridge to drop this peer's terminal tap, then forget it.
                self.onTerminalControl?(.detach, client)
                self.byClient[client] = nil
                self.conns[oid] = nil
            default: break
            }
        }
        conns[oid] = entry
        byClient[client] = oid
        conn.start(queue: q)
    }

    /// Read from a peer, reassembling frames across TCP segments (same stream-buffer
    /// idiom as `PeerConnector`). Snapshot/hello/heartbeat are ignored; terminal
    /// control frames are decoded and forwarded to `onTerminalControl`.
    private func receiveLoop(_ entry: Conn) {
        entry.nw.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                entry.buffer.append(data)
                self.drainFrames(entry)
            }
            if isComplete || error != nil { entry.nw.cancel(); return }
            self.receiveLoop(entry)
        }
    }

    private func drainFrames(_ entry: Conn) {
        while true {
            do {
                guard let (msg, consumed) = try PeerMessage.decode(from: entry.buffer) else { return }
                entry.buffer.removeFirst(consumed)
                if let control = PeerTerminal.control(from: msg) {
                    onTerminalControl?(control, entry.id)
                }
            } catch {
                entry.buffer.removeAll()   // corrupt stream — reset the connection
                entry.nw.cancel()
                return
            }
        }
    }
}
