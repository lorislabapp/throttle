import Foundation

/// Client for ttyd's wire protocol over WebSocket — the counterpart to the edge
/// agent's `/sessions/:id/attach` route (`throttle-agent.mjs`). ttyd frames are
/// binary WS frames with a leading command byte (`'0'` input/output, `'1'`
/// resize/title, `'2'`/`'3'` flow control); the very first client→server message is
/// a JSON auth/geometry handshake. No off-the-shelf Swift implementation of this
/// protocol exists (checked) — this hand-rolls the minimal subset Throttle needs:
/// auth handshake, output, input, resize. Flow-control pause/resume is unimplemented
/// (both ends are fast enough for a single interactive session in v1).
///
/// `@unchecked Sendable`: all mutable state is confined to the serial queue `q`,
/// matching `PeerConnector`'s concurrency shape; callbacks are `@Sendable` and fire
/// on `q`.
public final class TtydClient: @unchecked Sendable {
    public enum TtydError: Error { case badURL }

    private let q = DispatchQueue(label: "throttle.ttyd.client")
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    /// Fired with each decoded output chunk (PTY bytes, ready to feed a terminal emulator).
    public var onOutput: (@Sendable ([UInt8]) -> Void)?
    /// Fired when the socket opens/closes. A `false` while `reconnecting` is true
    /// means "dropped, retrying" rather than "closed for good".
    public var onConnected: (@Sendable (Bool) -> Void)?
    /// Fired when an auto-reconnect attempt begins (UI can show "reconnecting…").
    public var onReconnecting: (@Sendable () -> Void)?

    // Stored so a dropped socket can be re-established without the caller re-driving
    // the attach handshake.
    private struct Params { let host: String; let port: Int; let path: String; let token: String; let cols: Int; let rows: Int; let secure: Bool }
    private var params: Params?
    private var closedByUser = false
    private var retry = 0
    private var pingItem: DispatchWorkItem?

    public init() {
        session = URLSession(configuration: .ephemeral)
    }

    deinit { task?.cancel(with: .goingAway, reason: nil) }

    /// The edge agent always spawns ttyd with `-c throttle:<token>` (see
    /// `throttle-agent.mjs`) — this is ttyd's fixed HTTP Basic Auth username.
    private static let ttydUser = "throttle"

    /// Connect to the agent's ttyd attach endpoint and send the auth handshake.
    /// `secure` should be false for a plain Tailscale-only deployment (matches the
    /// edge agent's own no-TLS posture — Tailscale is the encryption boundary).
    ///
    /// ttyd auth (verified against ttyd 1.7.7's `src/protocol.c`/`src/http.c` — no
    /// off-the-shelf client to copy, so this was confirmed by hand against a live
    /// instance): the WS upgrade itself needs `Authorization: Basic <b64>` where
    /// `<b64>` is base64("user:pass") (the exact string ttyd was started with via
    /// `-c`), AND the first JSON_DATA message's `"AuthToken"` field must be that
    /// *same* base64 string — not the raw token, and not the plaintext "user:pass".
    public func connect(host: String, port: Int, path: String = "/ws", token: String,
                        cols: Int, rows: Int, secure: Bool = false) {
        q.async { [self] in
            closedByUser = false
            params = Params(host: host, port: port, path: path, token: token, cols: cols, rows: rows, secure: secure)
            guard task == nil else { return }
            var comps = URLComponents()
            comps.scheme = secure ? "wss" : "ws"
            comps.host = host
            comps.port = port
            comps.path = path
            guard let url = comps.url else { onConnected?(false); return }
            let credentialB64 = Data("\(Self.ttydUser):\(token)".utf8).base64EncodedString()
            var req = URLRequest(url: url)
            req.setValue("tty", forHTTPHeaderField: "Sec-WebSocket-Protocol")
            req.setValue("Basic \(credentialB64)", forHTTPHeaderField: "Authorization")
            let t = session.webSocketTask(with: req)
            task = t
            t.resume()

            let handshake: [String: Any] = ["AuthToken": credentialB64, "columns": cols, "rows": rows]
            guard let data = try? JSONSerialization.data(withJSONObject: handshake) else {
                onConnected?(false); return
            }
            t.send(.data(data)) { [weak self] error in
                guard let self else { return }
                self.q.async {
                    if error != nil { self.dropped(); return }
                    self.retry = 0
                    self.onConnected?(true)
                    self.schedulePing()
                    self.receiveLoop()
                }
            }
        }
    }

    /// 20s app-level ping so a half-open socket (NAT drop, sleep) is detected
    /// promptly instead of hanging until the next read fails.
    private func schedulePing() {
        pingItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let t = self.task else { return }
            t.sendPing { [weak self] err in
                guard let self else { return }
                self.q.async { if err != nil { self.dropped() } else { self.schedulePing() } }
            }
        }
        pingItem = item
        q.asyncAfter(deadline: .now() + 20, execute: item)
    }

    /// Socket died unexpectedly → notify (still "not connected") and, unless the
    /// caller closed it, reconnect with capped exponential backoff.
    private func dropped() {
        pingItem?.cancel(); pingItem = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        onConnected?(false)
        guard !closedByUser, let p = params else { return }
        retry = min(retry + 1, 6)
        let delay = min(pow(2.0, Double(retry)), 30) // 2,4,8,16,30,30…
        onReconnecting?()
        q.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.closedByUser else { return }
            self.connect(host: p.host, port: p.port, path: p.path, token: p.token,
                         cols: p.cols, rows: p.rows, secure: p.secure)
        }
    }

    public func sendInput(_ bytes: [UInt8]) {
        q.async { [self] in
            guard let t = task else { return }
            var frame = Data([0x30]) // '0' INPUT
            frame.append(contentsOf: bytes)
            t.send(.data(frame)) { _ in }
        }
    }

    public func sendResize(cols: Int, rows: Int) {
        q.async { [self] in
            guard let t = task,
                  let json = try? JSONSerialization.data(withJSONObject: ["columns": cols, "rows": rows])
            else { return }
            var frame = Data([0x31]) // '1' RESIZE_TERMINAL
            frame.append(json)
            t.send(.data(frame)) { _ in }
        }
    }

    public func disconnect() { q.async { [self] in closedByUser = true; teardown() } }

    // MARK: - private (all on q)

    private func teardown() {
        pingItem?.cancel(); pingItem = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        onConnected?(false)
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.q.async {
                switch result {
                case .failure:
                    self.dropped()
                case .success(let message):
                    if case .data(let d) = message { self.handle(d) }
                    // ttyd's output/title/prefs frames are always binary; a stray
                    // text frame here would only be a server bug — ignore it.
                    self.receiveLoop()
                }
            }
        }
    }

    private func handle(_ data: Data) {
        guard let first = data.first else { return }
        switch first {
        case 0x30: // '0' OUTPUT
            onOutput?(Array(data.dropFirst()))
        default:
            break // window title ('1') / preferences ('2') — ignored in v1
        }
    }
}
