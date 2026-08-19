import Foundation
import Network
import GRDB

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
    private final class WriterBox: @unchecked Sendable {
        let value: any DatabaseWriter

        init(_ value: any DatabaseWriter) {
            self.value = value
        }
    }

    static let shared = WebRenderBridge()

    private let port: UInt16
    private let q = DispatchQueue(label: "throttle.web.bridge")
    private var listener: NWListener?
    private var writer: (any DatabaseWriter)?   // nil → cache disabled (e.g. CLI selftest)
    private(set) var isListening = false

    init(port: UInt16 = 4319) { self.port = port }

    /// `writer` enables the render cache (web_fetches + ContentStore). Pass the app's
    /// shared DB from AppDelegate; omit it (CLI selftest) to run cache-less.
    func start(writer: (any DatabaseWriter)? = nil) {
        guard listener == nil else { return }
        self.writer = writer
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
            // Loopback-only: reject any peer that isn't 127.0.0.1 / ::1. (Binding the
            // listener itself to loopback via requiredLocalEndpoint breaks the bind on
            // this stack, so we filter at accept time — this tool renders arbitrary
            // URLs and must not be reachable from the LAN.)
            guard Self.isLoopback(conn.endpoint) else {
                self.log("rejected non-loopback connection")
                conn.cancel(); return
            }
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
            let requestLine = header.split(separator: "\r\n").first.map(String.init) ?? ""
            let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            self.handle(conn, path: path, body: body)
        }
    }

    private func handle(_ conn: NWConnection, path: String, body: Data) {
        if path == "/summarize" { handleSummary(conn, body: body); return }
        if path == "/delegate" { handleDelegation(conn, body: body); return }
        guard path == "/render" else {
            send(conn, status: "404 Not Found", json: ["ok": false, "error": "unknown endpoint"]); return
        }
        guard UserDefaults.standard.bool(forKey: "throttleWebEnabled") else {
            send(conn, status: "403 Forbidden", json: ["ok": false, "error": "web research is disabled in Throttle"]); return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let url = obj["url"] as? String, !url.isEmpty else {
            send(conn, status: "400 Bad Request", json: ["ok": false, "error": "missing url"]); return
        }
        let wait = obj["wait"] as? String ?? "networkIdle"
        let waitSelector = obj["waitSelector"] as? String
        let maxChars = (obj["maxChars"] as? Int) ?? 12_000
        let timeoutMs = (obj["timeoutMs"] as? Int) ?? 15_000
        let useCache = (obj["useCache"] as? Bool) ?? true
        let query = obj["query"] as? String
        let ttl = TimeInterval((obj["ttlSeconds"] as? Int) ?? 3_600)
        let cacheWriter = writer.map(WriterBox.init)

        // Cache short-circuit: a recent identical render skips WKWebView entirely.
        if useCache, let writer, let hit = WebResearchCache.lookup(url, ttl: ttl, reader: writer) {
            let packet = ContextFirewall.packet(text: hit.text, source: url, query: query,
                                                maxCharacters: maxChars, untrusted: true)
            send(conn, status: "200 OK", json: [
                "ok": true, "text": packet.text, "title": "", "finalURL": url,
                "renderMs": 0, "truncated": packet.returnedCharacters < packet.originalCharacters,
                "originalID": packet.originalID, "waitReason": "cache",
                "cacheHit": true, "cacheAgeSec": hit.ageSeconds, "error": NSNull(),
            ])
            return
        }

        Task { @MainActor in
            // Extract a substantially larger source than the response budget. The
            // Context Firewall below selects exact evidence and archives this raw
            // extraction, instead of prefix-truncating before relevance is known.
            let extractionCap = min(max(maxChars * 8, 120_000), 500_000)
            let r = await WebRenderer.shared.render(url: url, wait: wait, waitSelector: waitSelector,
                                                    maxChars: extractionCap, timeoutMs: timeoutMs)
            let packet = r.ok ? ContextFirewall.packet(
                text: r.text, source: r.finalURL.isEmpty ? url : r.finalURL,
                query: query, maxCharacters: maxChars, untrusted: true
            ) : nil
            var payload: [String: Any] = [
                "ok": r.ok, "text": packet?.text ?? r.text, "title": r.title, "finalURL": r.finalURL,
                "renderMs": r.renderMs,
                "truncated": r.truncated || ((packet?.returnedCharacters ?? 0) < (packet?.originalCharacters ?? 0)),
                "waitReason": r.waitReason, "cacheHit": false,
            ]
            if let originalID = packet?.originalID { payload["originalID"] = originalID }
            else { payload["originalID"] = NSNull() }
            if let error = r.error { payload["error"] = error }
            else { payload["error"] = NSNull() }
            let nextLinks = WebNavigationPlanner.ranked(
                r.links, query: query, baseURL: r.finalURL.isEmpty ? url : r.finalURL
            )
            payload["links"] = nextLinks.map { ["url": $0.url, "label": $0.label] }
            let responseBody = Self.encode(payload)
            self.q.async { self.send(conn, status: "200 OK", body: responseBody) }
            // Record for future cache hits, off the response path so it never adds latency.
            if r.ok, let cacheWriter {
                let text = r.text, title = r.title
                DispatchQueue.global(qos: .utility).async {
                    WebResearchCache.record(
                        url: url, text: text, title: title, renderMs: r.renderMs,
                        sessionId: nil, writer: cacheWriter.value
                    )
                }
            }
        }
    }

    private func handleSummary(_ conn: NWConnection, body: Data) {
        guard LocalWorkerRouter.anyBackendAvailable else {
            send(conn, status: "409 Conflict", json: ["ok": false, "error": "install the embedded Qwen model in Throttle first (or configure a local worker server in AI Settings)"]); return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let throttleID = obj["throttleID"] as? String,
              let task = obj["task"] as? String,
              let data = ContentStore.get(throttleID),
              let source = String(data: data, encoding: .utf8) else {
            send(conn, status: "400 Bad Request", json: ["ok": false, "error": "invalid or expired throttle_id"]); return
        }
        let maxTokens = (obj["maxTokens"] as? Int) ?? 384
        Task {
            do {
                let (summary, backend) = try await LocalWorkerRouter.shared.summarize(
                    source: source, task: task, maxTokens: maxTokens
                )
                let response = Self.encode(["ok": true, "summary": summary, "backend": backend.rawValue, "error": NSNull()])
                self.q.async { self.send(conn, status: "200 OK", body: response) }
            } catch {
                let response = Self.encode(["ok": false, "error": error.localizedDescription])
                self.q.async { self.send(conn, status: "500 Internal Server Error", body: response) }
            }
        }
    }

    private func handleDelegation(_ conn: NWConnection, body: Data) {
        guard LocalDelegationService.isEnabled else {
            send(conn, status: "403 Forbidden", json: ["ok": false, "error": "local delegation is disabled in Throttle"]); return
        }
        guard LocalWorkerRouter.anyBackendAvailable else {
            send(conn, status: "409 Conflict", json: ["ok": false, "error": "install the embedded Qwen model in Throttle first (or configure a local worker server in AI Settings)"]); return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let throttleID = obj["throttleID"] as? String,
              let objective = obj["objective"] as? String,
              let rawKind = obj["kind"] as? String,
              let data = ContentStore.get(throttleID),
              let source = String(data: data, encoding: .utf8) else {
            send(conn, status: "400 Bad Request", json: ["ok": false, "error": "invalid request or expired throttle_id"]); return
        }
        switch LocalDelegationService.assess(kind: rawKind, objective: objective) {
        case .escalate(let reason):
            send(conn, status: "200 OK", json: ["ok": true, "status": "escalate", "reason": reason]); return
        case .allow(let kind):
            let maxTokens = (obj["maxTokens"] as? Int) ?? 384
            Task {
                do {
                    let result = try await LocalWorkerRouter.shared.delegate(
                        source: source, objective: objective, kind: kind, maxTokens: maxTokens
                    )
                    LocalDelegationService.record(result)
                    let response = Self.encode(["ok": true, "markdown": result.markdown, "status": result.status])
                    self.q.async { self.send(conn, status: "200 OK", body: response) }
                } catch {
                    let response = Self.encode(["ok": false, "error": error.localizedDescription])
                    self.q.async { self.send(conn, status: "500 Internal Server Error", body: response) }
                }
            }
        }
    }

    private func send(_ conn: NWConnection, status: String, json: [String: Any]) {
        send(conn, status: status, body: Self.encode(json))
    }

    private func send(_ conn: NWConnection, status: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func encode(_ json: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    // MARK: - HTTP helpers (shared shape with TraycerReceiver)

    /// True iff the connection's remote peer is the loopback interface.
    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a): return "\(a)".hasPrefix("127.")
        case .ipv6(let a): let s = "\(a)"; return s == "::1" || s.hasPrefix("::1%") || s.hasSuffix(":127.0.0.1")
        case .name(let n, _): return n == "localhost"
        @unknown default: return false
        }
    }

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
