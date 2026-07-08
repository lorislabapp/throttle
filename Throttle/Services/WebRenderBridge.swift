import Foundation
import Network

/// In-app loopback HTTP bridge (127.0.0.1:4319) that lets the GUI-less
/// `--mcp-server` CLI drive the in-app `WebRenderer`. The CLI can't host a
/// WKWebView (no NSApplication / run loop), so it POSTs a render request here; the
/// bridge hops to the main actor, renders, and returns the extracted text as JSON.
///
/// NWListener bind + `\r\n\r\n` framing cloned verbatim from `TraycerReceiver`
/// (the proven-under-hardened-runtime `import Network` pattern). Unlike the
/// fire-and-forget OTLP receiver, this one AWAITS the async render before sending
/// its response. Loopback-only, opt-in, fail-open: a bind conflict on 4319 logs
/// and disables — the CLI then degrades to an "open Throttle" note.
///
/// `@unchecked Sendable`: mutable state (`listener`, `isListening`) is confined to
/// the serial `q`; `WebRenderer` is `@MainActor` and reached only via a hop.
final class WebRenderBridge: @unchecked Sendable {
    static let shared = WebRenderBridge()

    private let port: UInt16
    private let q = DispatchQueue(label: "throttle.web.bridge")
    private var listener: NWListener?
    private(set) var isListening = false

    init(port: UInt16 = 4319) { self.port = port }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: params, on: nwPort) else {
            log("bind failed on \(port) — web bridge disabled (port taken?)")
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.isListening = true
            case .failed, .cancelled: self?.isListening = false; self?.listener = nil
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            conn.start(queue: self.q)
            self.serve(conn)
        }
        listener.start(queue: q)
        log("listening on 127.0.0.1:\(port)")
    }

    func stop() {
        listener?.cancel(); listener = nil; isListening = false
    }

    private func log(_ msg: String) {
        FileHandle.standardError.write(Data("throttle web-bridge: \(msg)\n".utf8))
    }

    // MARK: - One request (no keep-alive needed; the client sends one render per connection)

    private func serve(_ conn: NWConnection, carry: Data = Data()) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buffer = carry
            if let data { buffer.append(data) }

            guard let headerEnd = Self.range(of: Data("\r\n\r\n".utf8), in: buffer) else {
                if isComplete || error != nil { conn.cancel() } else { self.serve(conn, carry: buffer) }
                return
            }
            let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            let bodyStart = headerEnd.upperBound
            guard let cl = Self.headerValue("content-length", in: header).flatMap({ Int($0) }) else {
                self.send(conn, status: "400 Bad Request", json: ["ok": false, "error": "missing content-length"]); return
            }
            let have = buffer.distance(from: bodyStart, to: buffer.endIndex)
            guard have >= cl else {
                if isComplete || error != nil { conn.cancel() } else { self.serve(conn, carry: buffer) }
                return
            }
            let body = buffer.subdata(in: bodyStart..<buffer.index(bodyStart, offsetBy: cl))
            self.handle(conn, body: body)
        }
    }

    private func handle(_ conn: NWConnection, body: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let url = obj["url"] as? String, !url.isEmpty else {
            send(conn, status: "400 Bad Request", json: ["ok": false, "error": "missing url"]); return
        }
        let wait = obj["wait"] as? String ?? "networkIdle"
        let waitSelector = obj["waitSelector"] as? String
        let maxChars = (obj["maxChars"] as? Int) ?? 12_000
        let timeoutMs = (obj["timeoutMs"] as? Int) ?? 15_000

        Task { @MainActor in
            let r = await WebRenderer.shared.render(url: url, wait: wait, waitSelector: waitSelector,
                                                    maxChars: maxChars, timeoutMs: timeoutMs)
            let payload: [String: Any] = [
                "ok": r.ok, "text": r.text, "title": r.title, "finalURL": r.finalURL,
                "renderMs": r.renderMs, "truncated": r.truncated, "waitReason": r.waitReason,
                "error": r.error as Any,
            ]
            self.q.async { self.send(conn, status: "200 OK", json: payload) }
        }
    }

    private func send(_ conn: NWConnection, status: String, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - HTTP helpers (shared shape with TraycerReceiver)

    private static func headerValue(_ name: String, in header: String) -> String? {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == name {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func range(of needle: Data, in haystack: Data, from: Data.Index? = nil) -> Range<Data.Index>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var i = from ?? haystack.startIndex
        let end = haystack.index(haystack.endIndex, offsetBy: -needle.count)
        while i <= end {
            if haystack[i..<haystack.index(i, offsetBy: needle.count)].elementsEqual(needle) {
                return i..<haystack.index(i, offsetBy: needle.count)
            }
            i = haystack.index(after: i)
        }
        return nil
    }
}
