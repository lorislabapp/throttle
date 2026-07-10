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

    private var listener: NWListener?
    private var conns: [ObjectIdentifier: NWConnection] = [:]
    private var latest: Data?
    private var seq: UInt32 = 0

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
            for c in conns.values { c.send(content: frame, completion: .contentProcessed { _ in }) }
        }
    }

    // MARK: - private (all on q)

    private func teardown() {
        listener?.cancel(); listener = nil
        for c in conns.values { c.cancel() }
        conns.removeAll()
    }

    private func nextFrame(kind: PeerMessage.Kind, payload: Data) -> Data {
        seq &+= 1
        return PeerMessage(kind: kind, seq: seq, timestampMillis: PeerTLS.nowMillis(), payload: payload).encoded()
    }

    private func accept(_ conn: NWConnection) {
        let oid = ObjectIdentifier(conn)
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
                self.drain(conn)   // consume peer heartbeats/hello, keep the socket live
            case .failed, .cancelled:
                self.conns[oid] = nil
            default: break
            }
        }
        conns[oid] = conn
        conn.start(queue: q)
    }

    /// Read and discard whatever the peer sends (hello/heartbeat). We don't act on
    /// it — there's no control channel — but draining keeps the connection healthy.
    private func drain(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil { conn.cancel(); return }
            self.drain(conn)
        }
    }
}
