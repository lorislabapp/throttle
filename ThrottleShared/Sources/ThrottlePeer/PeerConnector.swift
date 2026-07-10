import Foundation
import Network

/// iOS (and later visionOS) side of the LAN mirror: browses for `_throttle._tcp`,
/// connects to the Mac over TLS-PSK, and hands each received snapshot payload to
/// `onSnapshot`. Opportunistic — used only when a peer is on the same network; the
/// CloudKit subscriber remains the off-LAN fallback and the caller reconciles by
/// `publishedAt` so neither path regresses the other.
///
/// `@unchecked Sendable`: all mutable state is confined to the serial queue `q`;
/// callbacks are `@Sendable` and fire on `q`. `onSnapshot` receives the raw encoded
/// `ThrottleMirrorSnapshot` bytes (Sendable `Data`) so the connector never depends
/// on the app's UI layer.
public final class PeerConnector: @unchecked Sendable {

    private let secret: PeerPairingSecret
    private let q = DispatchQueue(label: "throttle.peer.connector")

    private var browser: NWBrowser?
    private var conn: NWConnection?
    private var buffer = Data()
    private var seq: UInt32 = 0

    /// Fired with each received snapshot payload (already `encoded()`).
    public var onSnapshot: (@Sendable (Data) -> Void)?
    /// Fired when the peer connection comes up / goes down.
    public var onConnected: (@Sendable (Bool) -> Void)?

    public init(secret: PeerPairingSecret) { self.secret = secret }

    /// Start browsing. Never throws — no peer found just means the fallback is used.
    public func start() {
        q.async { [self] in
            guard browser == nil else { return }
            let params = NWParameters()
            params.includePeerToPeer = true
            let b = NWBrowser(for: .bonjour(type: PeerPairing.serviceType, domain: nil), using: params)
            b.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self else { return }
                // Connect to the first advertised Mac we see (single-Mac v1).
                if self.conn == nil, let first = results.first {
                    self.connect(to: first.endpoint)
                }
            }
            b.start(queue: q)
            browser = b
        }
    }

    public func stop() {
        q.async { [self] in
            browser?.cancel(); browser = nil
            conn?.cancel(); conn = nil
            buffer.removeAll()
        }
    }

    // MARK: - private (all on q)

    private func connect(to endpoint: NWEndpoint) {
        let c = NWConnection(to: endpoint, using: PeerTLS.parameters(secret: secret))
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onConnected?(true)
                self.seq &+= 1
                let hello = PeerMessage(kind: .hello, seq: self.seq,
                                        timestampMillis: PeerTLS.nowMillis(),
                                        payload: Data("ios".utf8)).encoded()
                c.send(content: hello, completion: .contentProcessed { _ in })
                self.receiveLoop()
            case .failed, .cancelled:
                self.onConnected?(false)
                self.conn = nil
                self.buffer.removeAll()
            default: break
            }
        }
        conn = c
        c.start(queue: q)
    }

    private func receiveLoop() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainFrames()
            }
            if isComplete || error != nil {
                self.conn?.cancel(); self.conn = nil; self.onConnected?(false)
                return
            }
            self.receiveLoop()
        }
    }

    /// Decode every whole frame currently buffered; snapshots go to `onSnapshot`.
    private func drainFrames() {
        while true {
            do {
                guard let (msg, consumed) = try PeerMessage.decode(from: buffer) else { return }
                buffer.removeFirst(consumed)
                if msg.kind == .snapshot { onSnapshot?(msg.payload) }
            } catch {
                // Corrupt stream — drop the buffer and let the connection reset.
                buffer.removeAll()
                conn?.cancel()
                return
            }
        }
    }
}
